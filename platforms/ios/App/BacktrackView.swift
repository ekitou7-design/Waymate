import MapKit
import MotoNavigationCore
import SwiftUI

struct BacktrackReadout {
    let progress: BacktrackProgress
    let paused: Bool
    var status: String {
        if paused { return "RIDE PAUSED" }
        if progress.arrived { return "START REACHED" }
        switch progress.locationValidity {
        case .waiting: return "WAITING FOR GPS"
        case .poorAccuracy: return "GPS ACCURACY LOW"
        case .stale: return "LOCATION STALE"
        case .jumpRejected: return "LOCATION JUMP"
        case .unavailable: return "LOCATION UNAVAILABLE"
        case .usable: break
        }
        if progress.trailGap { return "TRAIL GAP" }
        if progress.offTrack { return "OFF TRACK" }
        return "FOLLOW TRAIL"
    }
    var canGuide: Bool { !paused && !progress.arrived && progress.locationValidity == .usable }
    static func distance(_ meters: Double?) -> String {
        guard let meters else { return "--" }
        return meters >= 1_000 ? String(format: "%.1f km", meters / 1_000) : String(format: "%.0f m", meters)
    }
}

struct BacktrackView: View {
    @ObservedObject var model: AppModel
    let navigate: () -> Void
    @State private var confirmsEndRide = false

    var body: some View {
        ScrollView {
            if let session = model.backtrackSession {
                let progress = session.progress
                let readout = BacktrackReadout(progress: progress, paused: model.rideSessionState == .paused)
                VStack(alignment: .leading, spacing: 24) {
                    Text("BACKTRACK").font(.title.weight(.semibold)).foregroundStyle(WaymateTheme.accent)
                    Text(readout.status).font(.headline)
                        .foregroundStyle(progress.offTrack || progress.trailGap ? WaymateTheme.warning : WaymateTheme.accent)
                        .accessibilityIdentifier("backtrack-status")
                    if readout.canGuide {
                        if let angle = progress.relativeDirection ?? progress.targetBearing {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 64, weight: .medium))
                                .rotationEffect(.degrees(angle))
                                .foregroundStyle(WaymateTheme.accent)
                                .frame(width: 100, height: 100)
                                .accessibilityLabel(progress.relativeDirection == nil
                                    ? "目标方位，北为上，\(Int(angle))度" : "相对行进方向，\(Int(angle))度")
                                .accessibilityIdentifier("backtrack-direction")
                            Text(progress.relativeDirection == nil ? "N ↑ · 绝对方位，北为上" : "相对当前行进方向")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(BacktrackReadout.distance(progress.distanceToTarget))
                            .font(.largeTitle.weight(.semibold)).monospacedDigit()
                            .accessibilityIdentifier("backtrack-target-distance")
                        Text(progress.trailGap ? "TO NEXT RECORDED SEGMENT" : (progress.offTrack ? "RETURN TO TRAIL" : "TO BREADCRUMB TARGET"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("RETURN TO START").font(.headline)
                    Text(BacktrackReadout.distance(progress.remainingDistance))
                        .font(.title2.weight(.medium)).monospacedDigit()
                        .accessibilityIdentifier("backtrack-remaining-distance")
                    Text("剩余实际轨迹距离 · 不含轨迹断点间的距离")
                        .font(.caption).foregroundStyle(.secondary)
                    if progress.trailGap {
                        Text("前方没有连续记录的轨迹。请自行确认通行条件，接回下一段已记录轨迹；地图不连接断点。")
                            .font(.subheadline).foregroundStyle(WaymateTheme.warning)
                    }
                    if progress.arrived { Text("RIDE CONTINUES · Ride 继续记录").font(.headline) }
                    if readout.paused { Text("恢复 Ride 后，等待新位置再继续指导。").font(.subheadline) }
                    BacktrackRouteMap(route: session.route, progress: progress).id(session.route.id)
                    Text("沿启动时已骑过的轨迹返回。返程继续记录在本次 Ride 中。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(model.device.supportsBacktrack ? "已连接支持原路返回的圆屏。" : "圆屏指导需要连接支持 Backtrack 的设备。")
                        .font(.footnote).foregroundStyle(.secondary)
                    RideMetricsView(model: model, compact: true)
                    HStack(spacing: 24) {
                        if model.rideSessionState == .paused {
                            Button("RESUME", action: model.resumeRide).accessibilityIdentifier("ride-resume-button")
                        } else {
                            Button("PAUSE", action: model.pauseRide).accessibilityIdentifier("ride-pause-button")
                        }
                        Button("END RIDE", role: .destructive) { confirmsEndRide = true }
                            .accessibilityIdentifier("ride-end-button")
                    }.font(.headline).frame(minHeight: 44)
                    Button("NAVIGATE · 选择目的地", action: navigate)
                        .frame(minHeight: 44).accessibilityIdentifier("backtrack-navigate-button")
                    Button("END BACKTRACK", action: model.endBacktrack)
                        .frame(minHeight: 44).accessibilityIdentifier("backtrack-end-button")
                }.padding(24)
            }
        }
        .buttonStyle(.plain)
        .background(WaymateTheme.background)
        .navigationTitle("原路返回")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.colorScheme, .dark)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(WaymateTheme.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .accessibilityIdentifier("backtrack-screen")
        .confirmationDialog("结束当前 Ride？", isPresented: $confirmsEndRide, titleVisibility: .visible) {
            Button("结束 Ride", role: .destructive, action: model.stopRide)
            Button("取消", role: .cancel) {}
        } message: { Text("结束原路返回并保存完整 Ride 记录。") }
    }
}

/// Map overlays are actual segments, including partial completion of the active one.
/// The gap has no polyline, even when guidance points at its opposite endpoint.
struct BacktrackMapGeometry {
    let route: BacktrackRoute
    let progress: BacktrackProgress
    var completed: [[WGS84Point]] {
        var lines = route.segments.prefix(progress.segmentIndex).map(\.points)
        let segment = route.segments[progress.segmentIndex]
        let edge = segment.edge(at: progress.segmentDistance)
        var partial = Array(segment.points.prefix(edge + 1))
        partial.append(segment.point(at: progress.segmentDistance))
        lines.append(partial)
        return lines
    }
}

private struct BacktrackRouteMap: View {
    let route: BacktrackRoute
    let progress: BacktrackProgress
    var body: some View {
        Map(initialPosition: .rect(bounds)) {
            ForEach(route.segments.indices, id: \.self) { index in
                if route.segments[index].points.count > 1 {
                    MapPolyline(coordinates: route.segments[index].points.map(coordinate))
                        .stroke(WaymateTheme.ice, lineWidth: 5)
                }
                if index > 0 {
                    Annotation("轨迹断点", coordinate: coordinate(route.segments[index].points[0])) {
                        Image(systemName: "circle.dashed").foregroundStyle(WaymateTheme.warning)
                    }
                }
            }
            let completed = BacktrackMapGeometry(route: route, progress: progress).completed
            ForEach(completed.indices, id: \.self) { index in
                if completed[index].count > 1 {
                    MapPolyline(coordinates: completed[index].map(coordinate))
                        .stroke(WaymateTheme.graphite, lineWidth: 5)
                }
            }
            Annotation("Ride Start", coordinate: coordinate(route.rideStart)) {
                Image(systemName: "flag.circle.fill").font(.title2).foregroundStyle(WaymateTheme.ice)
                    .padding(4).background(WaymateTheme.black, in: Circle())
            }
            if let point = progress.currentPosition {
                Annotation("当前位置", coordinate: coordinate(point)) {
                    Circle().fill(WaymateTheme.white).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(WaymateTheme.black, lineWidth: 3))
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityLabel("已骑过的回程轨迹，亮色为剩余，深色为已回溯，断点保持分开")
        .accessibilityIdentifier("backtrack-actual-trail-map")
    }
    private func coordinate(_ p: WGS84Point) -> CLLocationCoordinate2D {
        .init(latitude: p.latitudeDeg, longitude: p.longitudeDeg)
    }
    private var bounds: MKMapRect {
        var rect = MKMapRect.null
        for segment in route.segments {
            for point in segment.points {
                let p = MKMapPoint(coordinate(point))
                rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 1, height: 1))
            }
        }
        return rect.insetBy(dx: -max(200, rect.width * 0.15), dy: -max(200, rect.height * 0.15))
    }
}
