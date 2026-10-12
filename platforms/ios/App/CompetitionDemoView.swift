import SwiftUI
import MotoNavigationCore

struct CompetitionDemoView: View {
    @ObservedObject var demo: CompetitionDemo
    @ObservedObject var model: AppModel
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Text("DEMO / 模拟演示").font(.headline).foregroundStyle(.orange)
                        .accessibilityIdentifier("competition-demo-label")
                    Text("固定模拟输入 · 不使用实时定位或在线路线 · 不保存到骑行记录")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack {
                        Text(demo.title).font(.headline)
                        Spacer()
                        Text("\(demo.second) / \(CompetitionDemo.duration) s").monospacedDigit()
                    }
                    Text("模拟圆屏 / DEMO PREVIEW").font(.caption.weight(.semibold))
                    roundPreview
                    if demo.phase == .navigation {
                        Text("模拟目的地 · 演示终点")
                        Text(String(format: "剩余总距离 %.0f m · 预计剩余 %u s", demo.snapshot.remainingDistanceM, demo.snapshot.remainingDurationS))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        DemoTrail(track: demo.ride.track, current: demo.backtrack?.progress.currentPosition)
                            .frame(height: 100)
                        Text(String(format: "模拟 Ride · 已记录 %.0f m · %d 个轨迹点", demo.ride.distance, demo.ride.track.count))
                            .font(.caption)
                    }
                    DeviceStatusView(device: model.device)
                    if demo.phase == .backtrack && model.deviceReady && !model.device.supportsBacktrack {
                        Text("当前设备未声明 Backtrack 支持；此阶段请录制手机预览。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        Button(demo.running ? "暂停" : demo.completed ? "已完成" : demo.second == 0 ? "开始" : "继续") {
                            demo.running ? demo.pause() : demo.play()
                        }.disabled(demo.completed).accessibilityIdentifier("competition-demo-play")
                        Spacer()
                        Button("重播", action: demo.replay).accessibilityIdentifier("competition-demo-replay")
                        Spacer()
                        Button("下一步", action: demo.next).disabled(demo.completed)
                            .accessibilityIdentifier("competition-demo-next")
                    }.buttonStyle(.bordered).frame(minHeight: 44)
                    HStack {
                        ForEach(CompetitionDemo.Phase.allCases, id: \.self) { phase in
                            Button(phase.rawValue) { demo.jump(to: phase) }
                                .accessibilityIdentifier("competition-demo-\(phase.rawValue.lowercased())")
                        }
                    }.buttonStyle(.bordered)
                    Picker("模拟路线", selection: Binding(get: { demo.scenario }, set: demo.selectScenario)) {
                        ForEach(CompetitionDemo.Scenario.allCases, id: \.self) { route in Text(route.rawValue).tag(route) }
                    }.pickerStyle(.menu).accessibilityIdentifier("competition-demo-route-scenario")
                    Text(demo.running ? "自动播放中" : demo.completed ? "模拟演示完成" : "已暂停 · 可以手动推进")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }
            .background(WaymateTheme.background)
            .navigationTitle("演示模式")
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("退出演示", action: model.exitCompetitionDemo).accessibilityIdentifier("competition-demo-exit")
            } }
        }.tint(WaymateTheme.accent).interactiveDismissDisabled()
    }
    private var roundPreview: some View {
        Group {
            if demo.phase == .navigation {
                RouteFirstRoundPreview(snapshot: demo.snapshot)
            } else {
                VStack(spacing: 8) {
                    Text("DEMO").font(.caption.weight(.bold)).foregroundStyle(.orange)
                    if demo.phase == .ride {
                        Text("RIDE").font(.largeTitle.weight(.semibold))
                        Text(String(format: "%.0f", (demo.ride.currentSpeed(at: demo.demoDate) ?? 0) * 3.6))
                            .font(.system(size: 60, weight: .semibold)).monospacedDigit()
                        Text("km/h · 模拟骑行").font(.caption)
                    } else if let p = demo.backtrack?.progress {
                        Text("BACKTRACK").font(.title2.weight(.semibold))
                        Text(p.arrived ? "已返回起点" : String(format: "%.0f m", p.remainingDistance))
                            .font(.system(size: p.arrived ? 28 : 46, weight: .semibold)).monospacedDigit()
                        Text("返回剩余距离").font(.caption)
                        Text(p.arrived ? "模拟返回完成" : "沿已记录轨迹返回").font(.headline)
                    }
                }.foregroundStyle(.white).padding(20)
            }
        }.frame(maxWidth: 310).frame(height: 310)
            .background(.black, in: Circle()).overlay(Circle().stroke(WaymateTheme.accent.opacity(0.5), lineWidth: 2))
    }

}

/// An offline plot of the actual in-memory Demo Ride points; no map service.
private struct DemoTrail: View {
    let track: [RideTrackPoint]
    let current: WGS84Point?
    var body: some View {
        Canvas { context, size in
            guard let first = track.first else { return }
            let points = track.map { WGS84Point(longitudeDeg: $0.longitude, latitudeDeg: $0.latitude) }
            let scaleX = cos(first.latitude * .pi / 180)
            let xy = points.map { CGPoint(x: ($0.longitudeDeg-first.longitude)*scaleX, y: first.latitude-$0.latitudeDeg) }
            let maxX = max(0.0001, xy.map(\.x).max() ?? 0)
            let maxY = max(0.0001, xy.map(\.y).max() ?? 0)
            let scale = min((size.width-20)/maxX, (size.height-20)/maxY)
            func project(_ p: CGPoint) -> CGPoint { .init(x: 10+p.x*scale, y: 10+p.y*scale) }
            var path = Path(); path.move(to: project(xy[0]))
            for p in xy.dropFirst() { path.addLine(to: project(p)) }
            context.stroke(path, with: .color(WaymateTheme.accent), lineWidth: 3)
            if let current {
                let p = project(.init(x: (current.longitudeDeg-first.longitude)*scaleX, y: first.latitude-current.latitudeDeg))
                context.fill(Path(ellipseIn: CGRect(x: p.x-4, y: p.y-4, width: 8, height: 8)), with: .color(.orange))
            }
        }.accessibilityLabel("模拟 Ride 轨迹，\(track.count) 个点")
    }
}

/// Uses the same 466px projected route points as the shared ESP32 Presenter.
struct RouteFirstRoundPreview: View {
    let snapshot: MotoNavCoreSnapshot
    var body: some View {
        let state = NavigationComponentState(snapshot: snapshot)
        let readout = NavigationReadout(state: state, failure: nil)
        GeometryReader { geometry in
            let scale = geometry.size.width / 466
            ZStack {
                NavigationJunctionMap(snapshot: snapshot, simulated: true)
                if !state.arrived {
                    Canvas { context, size in
                        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                        let radius = 204.5 * scale
                        var track = Path(); track.addArc(center: centre, radius: radius, startAngle: .degrees(48), endAngle: .degrees(132), clockwise: false)
                        context.stroke(track, with: .color(.gray.opacity(0.4)), style: .init(lineWidth: 4 * scale, lineCap: .round))
                        let progress = snapshot.totalDistanceM > 0 ? min(1, max(0, snapshot.routeProgressM / snapshot.totalDistanceM)) : 0
                        if progress > 0 {
                            var fill = Path(); fill.addArc(center: centre, radius: radius, startAngle: .degrees(48), endAngle: .degrees(48 + 84 * progress), clockwise: false)
                            context.stroke(fill, with: .color(.white), style: .init(lineWidth: 5 * scale, lineCap: .round))
                        }
                    }
                }
                if state.arrived {
                    Image(systemName: "flag.checkered").font(.system(size: 42)).position(x: 233 * scale, y: 170 * scale)
                    Text("已到达").font(.title2).position(x: 233 * scale, y: 265 * scale)
                        .accessibilityIdentifier("competition-demo-distance")
                } else {
                    Text(snapshot.routeDirection).font(.system(size: 28 * scale, weight: .medium))
                        .position(x: 233 * scale, y: 42 * scale)
                        .accessibilityIdentifier("competition-demo-direction")
                    if readout.canShowManeuver {
                        if snapshot.miniMapPoints.count < 2 {
                            Text("ROUTE UNAVAILABLE").font(.system(size: 16 * scale)).foregroundStyle(.gray)
                                .position(x: 233 * scale, y: 210 * scale)
                        }
                        Image(systemName: readout.maneuver.symbol).font(.system(size: 34 * scale, weight: .semibold))
                            .position(x: 105 * scale, y: 345 * scale).accessibilityLabel(readout.maneuver.label)
                        HStack(alignment: .lastTextBaseline, spacing: 8 * scale) {
                            Text(snapshot.distanceToManeuverM >= 1_000 ? String(format: "%.1f", snapshot.distanceToManeuverM / 1_000) : String(format: "%.0f", snapshot.distanceToManeuverM))
                                .font(.system(size: 56 * scale, weight: .semibold)).monospacedDigit()
                            Text(snapshot.distanceToManeuverM >= 1_000 ? "km" : "m")
                                .font(.system(size: 20 * scale)).foregroundStyle(.gray)
                        }.position(x: 235 * scale, y: 343 * scale)
                            .accessibilityIdentifier("competition-demo-distance")
                        Text(snapshot.instructionText.isEmpty ? "沿路线前进" : snapshot.instructionText)
                            .font(.system(size: 28 * scale)).position(x: 233 * scale, y: 395 * scale)
                            .accessibilityIdentifier("competition-demo-action")
                    } else {
                        Text(readout.status).font(.headline).position(x: 233 * scale, y: 220 * scale)
                        Text("--").font(.title).position(x: 233 * scale, y: 343 * scale)
                    }
                }
                Text("DEMO").font(.system(size: 16 * scale, weight: .bold)).foregroundStyle(.orange)
                    .position(x: 233 * scale, y: 430 * scale)
            }.foregroundStyle(.white)
        }
    }
}
struct NavigationJunctionMap: View {
    let snapshot: MotoNavCoreSnapshot
    var simulated = false
    var body: some View {
        Canvas { context, size in
            guard snapshot.stateName != "arrived", snapshot.hasUsableFix,
                  !snapshot.gnssStale, !snapshot.offRoute, snapshot.stateName != "rerouting" else { return }
            let scale = size.width / 466
            let rect = CGRect(x: 74 * scale, y: 66 * scale, width: 318 * scale, height: 234 * scale)
            context.clip(to: Path(rect))
            guard snapshot.miniMapPoints.count >= 2 else { return }
            func point(_ p: MotoNavMapPointValue) -> CGPoint { .init(x: Double(p.x) * scale, y: Double(p.y) * scale) }
            var route = Path(); route.move(to: point(snapshot.miniMapPoints[0]))
            for p in snapshot.miniMapPoints.dropFirst() { route.addLine(to: point(p)) }
            context.stroke(route, with: .color(.gray.opacity(0.35)), style: .init(lineWidth: 17 * scale, lineCap: .round, lineJoin: .round))
            context.stroke(route, with: .color(.white), style: .init(lineWidth: 13 * scale, lineCap: .round, lineJoin: .round))
            var marker = Path(); marker.move(to: .init(x: 233 * scale, y: 254 * scale))
            marker.addLine(to: .init(x: 213 * scale, y: 294 * scale))
            marker.addLine(to: .init(x: 233 * scale, y: 284 * scale))
            marker.addLine(to: .init(x: 253 * scale, y: 294 * scale)); marker.closeSubpath()
            context.stroke(marker, with: .color(.black), style: .init(lineWidth: 5 * scale, lineJoin: .round))
            context.fill(marker, with: .color(.white))
        }.accessibilityLabel(simulated ? "模拟规划路线，中央微型地图" : "当前规划路线地图")
            .accessibilityIdentifier(simulated ? "competition-demo-junction-map" : "navigation-junction-map")
    }
}
