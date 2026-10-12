import MapKit
import MotoNavigationCore
import SwiftUI

struct RouteOverviewMap: UIViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let candidates: [RoutePreviewCandidate]
    let selectedID: String?
    let origin: WGS84Point?
    let destination: WGS84Point

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.registerForTraitChanges([
            UITraitUserInterfaceStyle.self,
            UITraitAccessibilityContrast.self
        ]) { [weak coordinator = context.coordinator] (mapView: MKMapView, _: UITraitCollection) in
            coordinator?.refreshRouteAppearance(on: mapView)
        }
        mapView.mapType = .mutedStandard
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.showsTraffic = true
        // This map is the route-selection overview, not a free-roaming map.
        // Let vertical gestures reach the enclosing SwiftUI ScrollView so all
        // route choices remain reachable instead of accidentally panning the
        // selected route out of view.
        mapView.isScrollEnabled = false
        mapView.isZoomEnabled = false
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.selectedID = selectedID
        let signature = candidates.map(\.id).joined(separator: "|") +
            "::" + (selectedID ?? "")
        guard context.coordinator.signature != signature else { return }
        context.coordinator.signature = signature

        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)

        let ordered = candidates.sorted { lhs, rhs in
            (lhs.id == selectedID ? 1 : 0) < (rhs.id == selectedID ? 1 : 0)
        }
        var allCoordinates: [CLLocationCoordinate2D] = []
        for candidate in ordered {
            let coordinates = candidate.route.polyline.map { point in
                let wgs84 = ChinaCoordinateTransform.gcj02ToWGS84(point)
                return CLLocationCoordinate2D(
                    latitude: wgs84.latitudeDeg,
                    longitude: wgs84.longitudeDeg
                )
            }
            guard coordinates.count >= 2 else { continue }
            let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
            polyline.title = candidate.id
            mapView.addOverlay(polyline, level: .aboveRoads)
            allCoordinates.append(contentsOf: coordinates)
        }

        if let origin {
            let annotation = MKPointAnnotation()
            annotation.coordinate = CLLocationCoordinate2D(
                latitude: origin.latitudeDeg,
                longitude: origin.longitudeDeg
            )
            annotation.title = "当前位置"
            annotation.subtitle = "moto-start"
            mapView.addAnnotation(annotation)
            allCoordinates.append(annotation.coordinate)
        }

        let destinationAnnotation = MKPointAnnotation()
        destinationAnnotation.coordinate = CLLocationCoordinate2D(
            latitude: destination.latitudeDeg,
            longitude: destination.longitudeDeg
        )
        destinationAnnotation.title = "目的地"
        destinationAnnotation.subtitle = "moto-finish"
        mapView.addAnnotation(destinationAnnotation)
        allCoordinates.append(destinationAnnotation.coordinate)

        guard !allCoordinates.isEmpty else { return }
        var visibleRect = MKMapRect.null
        for coordinate in allCoordinates {
            let point = MKMapPoint(coordinate)
            visibleRect = visibleRect.union(
                MKMapRect(x: point.x, y: point.y, width: 0.1, height: 0.1)
            )
        }
        mapView.setVisibleMapRect(
            visibleRect,
            edgePadding: UIEdgeInsets(top: 38, left: 30, bottom: 42, right: 30),
            animated: context.coordinator.hasPresentedRoute && !reduceMotion
        )
        context.coordinator.hasPresentedRoute = true
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var signature = ""
        var selectedID: String?
        var hasPresentedRoute = false

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: polyline)
            configure(renderer, for: polyline, traits: mapView.traitCollection)
            return renderer
        }

        func refreshRouteAppearance(on mapView: MKMapView) {
            // Overlay renderers draw resolved colors. Refresh their strokes when
            // appearance changes even if the route IDs have stayed the same.
            for overlay in mapView.overlays {
                guard let polyline = overlay as? MKPolyline,
                      let renderer = mapView.renderer(for: overlay) as? MKPolylineRenderer
                else { continue }
                configure(renderer, for: polyline, traits: mapView.traitCollection)
                renderer.setNeedsDisplay()
            }
        }

        private func configure(
            _ renderer: MKPolylineRenderer,
            for polyline: MKPolyline,
            traits: UITraitCollection
        ) {
            let isSelected = polyline.title == selectedID
            let color: UIColor = isSelected ? UIColor(WaymateTheme.accent) : UIColor(WaymateTheme.road)
            renderer.strokeColor = color.resolvedColor(with: traits)
            renderer.lineWidth = isSelected ? 7 : 5
            renderer.lineCap = .round
            renderer.lineJoin = .round
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let point = annotation as? MKPointAnnotation else { return nil }
            let identifier = "route-endpoint"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: point, reuseIdentifier: identifier)
            view.annotation = point
            let isStart = point.subtitle == "moto-start"
            view.markerTintColor = isStart ? UIColor(WaymateTheme.accent) : UIColor(WaymateTheme.error)
            view.glyphImage = UIImage(systemName: isStart ? "location.fill" : "flag.fill")
            view.glyphTintColor = UIColor(WaymateTheme.onAccent)
            view.subtitleVisibility = .hidden
            view.displayPriority = .required
            return view
        }
    }
}

/// Full phone map stays independent of the compact round-display layout.
/// Apple supplies the basemap; all overlays are the accepted route/GPS only.
struct ActiveNavigationMap: View {
    let points: [GCJ02Point]
    let snapshot: MotoNavCoreSnapshot
    @State private var position: MapCameraPosition = .automatic
    private var coordinates: [CLLocationCoordinate2D] {
        points.map { p in
            let wgs = ChinaCoordinateTransform.gcj02ToWGS84(p)
            return .init(latitude: wgs.latitudeDeg, longitude: wgs.longitudeDeg)
        }
    }
    var body: some View {
        let route = coordinates
        ZStack(alignment: .topTrailing) {
            Map(position: $position) {
                if route.count >= 2 {
                    MapPolyline(coordinates: route).stroke(WaymateTheme.accent, lineWidth: 6)
                }
                if snapshot.hasUsableFix && !snapshot.gnssStale && snapshot.hasRouteView {
                    let p = ChinaCoordinateTransform.gcj02ToWGS84(.init(longitudeDeg: snapshot.routeViewOriginLongitudeDeg, latitudeDeg: snapshot.routeViewOriginLatitudeDeg))
                    Annotation("当前位置", coordinate: .init(latitude: p.latitudeDeg, longitude: p.longitudeDeg)) {
                        Image(systemName: "location.fill").foregroundStyle(.white).padding(8)
                            .background(WaymateTheme.accent, in: Circle())
                    }
                }
                if let last = route.last { Marker("目的地", systemImage: "flag.fill", coordinate: last) }
            }.mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: true))
                .accessibilityIdentifier("navigation-full-map")
            Button("路线总览") { position = .automatic }
                .font(.caption.weight(.semibold)).padding(10).background(.regularMaterial, in: Capsule()).padding(10)
                .accessibilityIdentifier("navigation-route-overview")
        }
    }
}
