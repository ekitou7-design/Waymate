import MapKit
import SwiftUI

/// Contiguous segments of the recorded WGS84 points only. No route provider input.
enum RideRouteGeometry {
    static func segments(_ track: [RideTrackPoint]) -> [[RideTrackPoint]] {
        var segments: [[RideTrackPoint]] = []
        var current: [RideTrackPoint] = []
        for point in track {
            guard CLLocationCoordinate2DIsValid(.init(latitude: point.latitude, longitude: point.longitude)) else {
                if current.count >= 2 { segments.append(current) }
                current = []
                continue
            }
            if let last = current.last, last.segment != point.segment {
                if current.count >= 2 { segments.append(current) }
                current = []
            }
            current.append(point)
        }
        if current.count >= 2 { segments.append(current) }
        return segments
    }
}

struct RideRouteMap: View {
    let track: [RideTrackPoint]

    var body: some View {
        let segments = RideRouteGeometry.segments(track)
        if segments.isEmpty {
            ContentUnavailableView("Route unavailable", systemImage: "map",
                                   description: Text("本次 Ride 没有足够的实际 GPS 轨迹。"))
                .frame(height: 220)
                .accessibilityIdentifier("ride-route-unavailable")
        } else {
            Map(initialPosition: .rect(bounds(segments)), interactionModes: []) {
                ForEach(segments.indices, id: \.self) { index in
                    MapPolyline(coordinates: segments[index].map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    }).stroke(WaymateTheme.accent, lineWidth: 5)
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityLabel("本次 Ride 的实际 GPS 轨迹")
            .accessibilityIdentifier("ride-actual-track-map")
        }
    }

    private func bounds(_ segments: [[RideTrackPoint]]) -> MKMapRect {
        var rect = MKMapRect.null
        for point in segments.joined() {
            let p = MKMapPoint(CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
            rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 1, height: 1))
        }
        return rect.insetBy(dx: -max(200, rect.width * 0.15), dy: -max(200, rect.height * 0.15))
    }
}
