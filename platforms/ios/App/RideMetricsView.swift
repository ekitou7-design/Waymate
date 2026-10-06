import SwiftUI

/// Only metrics tick each second. No map, route request or screen timer lives here.
struct RideMetricsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    var compact = false
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize = 48

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: compact ? 12 : 24) {
                metric("骑行时间", value: duration(model.rideElapsedTime), id: "ride-elapsed-time", hero: !compact)
                if !compact {
                    metric("当前速度 · km/h", value: model.rideCurrentSpeed.map { String(format: "%.1f", $0 * 3.6) } ?? "--",
                           id: "ride-current-speed", hero: true)
                }
                if typeSize.isAccessibilitySize {
                    distanceMetric
                    movingMetric
                } else {
                    HStack(alignment: .top, spacing: 24) { distanceMetric; movingMetric }
                }
            }
            .monospacedDigit()
        }
    }

    private var distanceMetric: some View {
        metric("距离", value: String(format: "%.2f km", model.rideDistance / 1_000), id: "ride-distance")
    }

    private var movingMetric: some View {
        metric("移动时间", value: duration(model.rideMovingTime), id: "ride-moving-time")
    }

    private func metric(_ label: String, value: String, id: String, hero: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(hero ? .system(size: heroSize, weight: .semibold, design: .rounded) : .title2.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityIdentifier(id)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%02d:%02d:%02d", total / 3_600, total / 60 % 60, total % 60)
    }
}
