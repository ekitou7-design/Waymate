import SwiftUI

/// UI wording and glyphs only. NavCore remains the source of every condition.
struct NavigationReadout {
    let state: NavigationComponentState
    let failure: String?

    var status: String {
        if failure != nil { return "NAVIGATION UNAVAILABLE" }
        if state.arrived { return "ARRIVED" }
        if state.locationValidity.isStale { return "LOCATION STALE" }
        if !state.locationValidity.hasUsableFix { return "WAITING FOR GPS" }
        if state.phase == "rerouting" { return "REROUTING" }
        if state.offRoute { return "OFF ROUTE" }
        if !state.isNavigationValid { return "ROUTE LOADING" }
        return "NAVIGATION"
    }

    var canShowManeuver: Bool {
        failure == nil && state.phase == "navigating" && state.isNavigationValid &&
        state.locationValidity.hasUsableFix && !state.locationValidity.isStale && !state.offRoute
    }

    var maneuver: (symbol: String, label: String) {
        switch state.nextManeuver?.typeName {
        case "continue": return ("arrow.up", "继续直行")
        case "slight_left": return ("arrow.up.left", "向左前方")
        case "left": return ("arrow.turn.up.left", "左转")
        case "sharp_left": return ("arrow.turn.down.left", "向左急转")
        case "u_turn_left": return ("arrow.uturn.down", "向左掉头")
        case "slight_right": return ("arrow.up.right", "向右前方")
        case "right": return ("arrow.turn.up.right", "右转")
        case "sharp_right": return ("arrow.turn.down.right", "向右急转")
        case "u_turn_right": return ("arrow.uturn.down", "向右掉头")
        case "roundabout":
            let exit = state.nextManeuver?.roundaboutExit ?? 0
            return ("arrow.clockwise", exit > 0 ? "环岛 · 第 \(exit) 出口" : "进入环岛")
        case "exit": return ("arrow.up.right", "驶出")
        case "arrive": return ("flag.checkered", "到达目的地")
        default: return ("questionmark", "转向信息不可用")
        }
    }
}

struct ActiveNavigationView: View {
    let state: NavigationComponentState
    let failure: String?
    let destination: String
    let duration: String
    let distance: String
    let rideActive: Bool
    let ridePaused: Bool
    let demo: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var glyphSize = 64

    var body: some View {
        let readout = NavigationReadout(state: state, failure: failure)
        VStack(alignment: .leading, spacing: 24) {
            Text(readout.status)
                .font(.title.weight(.semibold))
                .foregroundStyle(readout.status == "NAVIGATION" || state.arrived ? WaymateTheme.accent : WaymateTheme.warning)
                .accessibilityIdentifier("navigation-status")
            if demo { Label("演示导航 · 模拟位置与行驶过程", systemImage: "info.circle").font(.footnote) }
            if state.arrived && failure == nil {
                Image(systemName: "flag.checkered").font(.largeTitle).accessibilityHidden(true)
                Text(destination).font(.title2)
                Text("已到达目的地").foregroundStyle(.secondary)
                if rideActive {
                    Text(ridePaused ? "RIDE REMAINS PAUSED · Ride 保持暂停" : "RIDE CONTINUES · Ride 继续记录")
                        .font(.headline).accessibilityIdentifier("navigation-ride-continues")
                }
            } else if readout.canShowManeuver, state.nextManeuver != nil {
                Image(systemName: readout.maneuver.symbol)
                    .font(.system(size: glyphSize, weight: .medium))
                    .foregroundStyle(WaymateTheme.accent).accessibilityHidden(true)
                Text(readout.maneuver.label).font(.title2.weight(.semibold))
                    .accessibilityIdentifier("navigation-maneuver")
                Text(state.distanceToManeuverM.map { $0 >= 1_000 ? String(format: "%.1f km", $0 / 1_000) : String(format: "%.0f m", $0) } ?? "--")
                    .font(.largeTitle.weight(.semibold)).monospacedDigit()
                    .accessibilityIdentifier("navigation-maneuver-distance")
                if let instruction = state.instruction { Text(instruction).font(.title3) }
                if let road = state.maneuverRoadName { Text(road).foregroundStyle(.secondary) }
            } else {
                Text(failure == nil ? warningDetail : "导航暂不可用。请检查网络、定位与网关配置。")
                    .font(.title3).fixedSize(horizontal: false, vertical: true)
                if let failure {
                    DisclosureGroup("错误详情") {
                        Text(failure).font(.footnote).textSelection(.enabled)
                    }
                }
                if state.isNavigationValid { Text("目的地 · \(destination)").foregroundStyle(.secondary) }
            }
            if state.isNavigationValid && !state.arrived {
                if typeSize.isAccessibilitySize {
                    estimate("预计剩余时间", value: duration)
                    estimate("剩余距离", value: distance)
                } else {
                    HStack(alignment: .top, spacing: 24) {
                        estimate("预计剩余时间", value: duration)
                        estimate("剩余距离", value: distance)
                    }
                }
                if !readout.canShowManeuver {
                    Text("路线估计，等待位置与路线更新").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var warningDetail: String {
        if state.locationValidity.isStale { return "位置已过期，请等待新的 GPS 定位。" }
        if !state.locationValidity.hasUsableFix { return "等待可用 GPS 定位，请保持精确定位开启。" }
        if state.phase == "rerouting" { return "正在重新规划路线，更新后继续指引。" }
        if state.offRoute { return "已偏离当前路线，请等待导航更新。" }
        if state.isNavigationValid { return "暂无下一步转向信息。" }
        return "正在获取路线；若长时间无响应，请检查网络与定位。"
    }

    private func estimate(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.title2.weight(.medium)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
