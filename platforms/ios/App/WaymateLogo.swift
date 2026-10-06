import SwiftUI

/// Geometric two-route W. Coordinates match generate_waymate_brand.swift.
struct WaymateMark: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        var path = Path()
        for route in [[CGPoint(x: 12, y: 30), CGPoint(x: 28, y: 74), CGPoint(x: 46, y: 20)],
                      [CGPoint(x: 54, y: 30), CGPoint(x: 70, y: 74), CGPoint(x: 88, y: 20)]] {
            let points = route.map { CGPoint(x: origin.x + $0.x * side / 100,
                                            y: origin.y + $0.y * side / 100) }
            path.move(to: points[0])
            points.dropFirst().forEach { path.addLine(to: $0) }
        }
        return path
    }
}

/// Mark only: wordmark is independently available as an outlined SVG asset.
/// Place on a brand-black surface by default, or supply a contrasting color.
struct WaymateLogo: View {
    var size: CGFloat = 32
    var color: Color = WaymateTheme.white

    var body: some View {
        WaymateMark()
            .stroke(color, style: WaymateTheme.waylineStroke(width: size * 0.08))
            .frame(width: size, height: size)
            .accessibilityLabel("waymate")
            .accessibilityAddTraits(.isImage)
    }
}

#Preview("Brand / compact sizes") {
    HStack(spacing: 24) {
        WaymateLogo(size: 24)
        WaymateLogo(size: 32)
        WaymateLogo(size: 120)
    }
    .padding(32)
    .background(WaymateTheme.black)
}
