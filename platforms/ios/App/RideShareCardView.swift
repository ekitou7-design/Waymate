import SwiftUI
import UIKit

/// Spherical Mercator in meters, longitude unwrapped across the date line.
/// One uniform fit scale; one subpath per recorded segment, never a gap bridge.
enum RideShareRoute {
    static func project(_ track: [RideTrackPoint], into size: CGSize, padding: CGFloat = 24) -> [[CGPoint]] {
        guard size.width > padding * 2, size.height > padding * 2 else { return [] }
        let segments = RideRouteGeometry.segments(track)
        guard let reference = segments.first?.first?.longitude else { return [] }
        let radius = 6_378_137.0
        var projected: [[CGPoint]] = []
        for segment in segments {
            var previous = reference
            var points: [CGPoint] = []
            for point in segment {
                // Mercator is undefined at the poles. Break rather than alter coordinates.
                guard abs(point.latitude) < 90 else {
                    if points.count >= 2 { projected.append(points) }
                    points = []
                    continue
                }
                let longitude = point.longitude + 360 * ((previous - point.longitude) / 360).rounded()
                previous = longitude
                points.append(CGPoint(x: radius * longitude * .pi / 180,
                                      y: -radius * asinh(tan(point.latitude * .pi / 180))))
            }
            if points.count >= 2 { projected.append(points) }
        }
        let points = projected.joined()
        guard let first = points.first else { return [] }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        // A stationary/very short track stays a small mark, with a 100 m minimum viewport.
        let scale = min((size.width - 2 * padding) / max(100, maxX - minX),
                        (size.height - 2 * padding) / max(100, maxY - minY))
        return projected.map { segment in
            segment.map { CGPoint(x: ($0.x - (minX + maxX) / 2) * scale + size.width / 2,
                                  y: ($0.y - (minY + maxY) / 2) * scale + size.height / 2) }
        }
    }

    static func path(_ segments: [[CGPoint]]) -> Path {
        Path { path in
            for segment in segments {
                guard let first = segment.first else { continue }
                path.move(to: first)
                for point in segment.dropFirst() { path.addLine(to: point) }
            }
        }
    }
}

struct RideShareCardView: View {
    let record: RideRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                WaymateLogo(size: 30)
                Text("waymate").font(.system(size: 25, weight: .semibold))
            }
            .padding(.bottom, 22)
            Text(record.displayName)
                .font(.system(size: 26, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.65)
                .frame(height: 64, alignment: .topLeading)
            Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 12)).foregroundStyle(WaymateTheme.white.opacity(0.65))
                .padding(.top, 3)
            route.frame(height: 210).padding(.vertical, 12)
            Text(RideDisplayFormat.distance(record.distance))
                .font(.system(size: 43, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            Rectangle().fill(WaymateTheme.graphite).frame(height: 1).padding(.vertical, 18)
            HStack(alignment: .top, spacing: 8) {
                metric("MOVING", RideDisplayFormat.duration(record.movingTime))
                metric("AVG", RideDisplayFormat.speed(record.averageSpeed))
                metric("MAX", RideDisplayFormat.speed(record.maxSpeed))
            }
            Spacer(minLength: 14)
            HStack {
                Text("Stay on your way.")
                Spacer()
                Text("ACTUAL GPS TRACK")
            }.font(.system(size: 9, weight: .medium))
                .foregroundStyle(WaymateTheme.white.opacity(0.55))
        }
        .padding(28)
        .frame(width: 540, height: 675)
        .foregroundStyle(WaymateTheme.white)
        .background(WaymateTheme.black)
    }

    private var route: some View {
        let segments = RideShareRoute.project(record.track, into: CGSize(width: 484, height: 210))
        return ZStack {
            if segments.isEmpty {
                Text("Route unavailable").font(.system(size: 15))
                    .foregroundStyle(WaymateTheme.white.opacity(0.55))
            } else {
                RideShareRoute.path(segments).stroke(WaymateTheme.ice, style: WaymateTheme.waylineStroke(width: 2.5))
                if let start = segments.first?.first {
                    Circle().fill(WaymateTheme.black).overlay(Circle().stroke(WaymateTheme.ice, lineWidth: 2))
                        .frame(width: 8, height: 8).position(start)
                }
                if let end = segments.last?.last {
                    Circle().fill(WaymateTheme.white).frame(width: 6, height: 6).position(end)
                }
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(WaymateTheme.ice)
            Text(value).font(.system(size: 14, weight: .medium)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.65)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum RideShareRenderer {
    enum RenderError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Unable to create share image" }
    }

    @MainActor static func image(for record: RideRecord) throws -> UIImage {
        let renderer = ImageRenderer(content: RideShareCardView(record: record)
            .environment(\.colorScheme, .dark)
            .environment(\.dynamicTypeSize, .medium))
        renderer.proposedSize = ProposedViewSize(width: 540, height: 675)
        renderer.scale = 2
        renderer.isOpaque = true
        guard let image = renderer.uiImage, let cgImage = image.cgImage,
              cgImage.width == 1080, cgImage.height == 1350 else { throw RenderError.unavailable }
        return image
    }
}
