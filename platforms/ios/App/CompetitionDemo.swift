import Combine
import Foundation
import MotoNavigationCore

/// An 84-second fixture, entirely in memory. No location source, provider,
/// persistence store or preferences are reachable from this owner.
@MainActor
final class CompetitionDemo: ObservableObject {
    enum Phase: String, CaseIterable { case navigation = "Navigation", ride = "Ride", backtrack = "Backtrack" }
    enum Scenario: String, CaseIterable { case rightLeft = "右转 → 左转", left = "左转", straight = "直行", sCurve = "连续弯道", uTurn = "掉头" }
    @Published private(set) var scenario: Scenario = .rightLeft
    private var fixture = Fixture(.rightLeft)
    static let duration = 84
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    @Published private(set) var second = 0
    @Published private(set) var running = false
    @Published private(set) var snapshot = MotoNavCoreBridge().snapshot
    @Published private(set) var ride = RideSession()
    @Published private(set) var backtrack: BacktrackSession?
    var onFrame: (() -> Void)?
    private var timer: Task<Void, Never>?
    private var returnRoute: BacktrackRoute?
    private let driver = PresentationDriver(schedulesExpiry: false)
    var phase: Phase { second < 44 ? .navigation : second < 64 ? .ride : .backtrack }
    var page: RoundDisplayPage { driver.selectedPage }
    var demoDate: Date { Self.epoch.addingTimeInterval(Double(second)) }
    var completed: Bool { second == Self.duration }
    var title: String { second < 5 ? "模拟路线规划" : phase.rawValue }
    var nextAction: String {
        NavigationReadout(state: .init(snapshot: snapshot), failure: nil).maneuver.label
    }

    // Fictional demonstration geometry in GCJ-02; these are not tested roads.
    static let origin = GCJ02Point(longitudeDeg: 121.47, latitudeDeg: 31.23)
    var route: [GCJ02Point] { fixture.points }
    var cumulative: [Double] { fixture.cumulative }
    var totalM: Double { cumulative.last! }
    private struct Fixture {
        let points: [GCJ02Point]
        let cumulative: [Double]
        let actions: [(Int, String, String)]
        init(_ scenario: Scenario) {
            let xy: [(Double, Double)]
            switch scenario {
            case .rightLeft: xy=[(0,0),(320,0),(320,-180),(440,-180)]; actions=[(1,"right","前方右转"),(2,"left","前方左转")]
            case .left: xy=[(0,0),(320,0),(320,180),(440,180)]; actions=[(1,"left","前方左转"),(2,"right","前方右转")]
            case .straight: xy=[(0,0),(320,0),(620,0)]; actions=[(1,"continue","继续直行")]
            case .sCurve:
                xy=[(0,0),(100,0),(135,-15),(160,-40),(175,-70),(180,-100),(195,-135),(220,-160),(255,-175),(300,-180),(420,-180)]
                actions=[(1,"slight_right","向右前方"),(5,"slight_left","向左前方")]
            case .uTurn:
                xy=[(0,0),(320,0),(345,-8),(360,-25),(365,-45),(360,-65),(345,-82),(320,-90),(200,-90),(80,-90)]
                actions=[(1,"u_turn_right","前方掉头")]
            }
            let latM=180/(.pi*BreadcrumbMath.radius)
            let lonM=latM/cos(CompetitionDemo.origin.latitudeDeg * .pi/180)
            points=xy.map { .init(longitudeDeg: CompetitionDemo.origin.longitudeDeg+$0.0*lonM,
                                  latitudeDeg: CompetitionDemo.origin.latitudeDeg+$0.1*latM) }
            var distances=[0.0]
            for i in 1..<points.count {
                let a=WGS84Point(longitudeDeg:points[i-1].longitudeDeg,latitudeDeg:points[i-1].latitudeDeg)
                let b=WGS84Point(longitudeDeg:points[i].longitudeDeg,latitudeDeg:points[i].latitudeDeg)
                distances.append(distances.last!+BreadcrumbMath.distance(a,b))
            }
            cumulative=distances
        }
    }
    func selectScenario(_ value: Scenario) {
        pause(); scenario=value; fixture=Fixture(value); returnRoute=nil; seek(to:5)
    }

    init() { seek(to: 0) }
    deinit { timer?.cancel() }

    func play() {
        guard !running, !completed else { return }
        running = true
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.advance()
            }
        }
    }
    func pause() { timer?.cancel(); timer = nil; running = false }
    func replay() { pause(); seek(to: 0); play() }
    func advance() {
        guard second < Self.duration else { pause(); return }
        seek(to: second + 1)
        if completed { pause() }
    }
    func next() {
        pause()
        let stops = [5, 11, 14, 17, 20, 25, 30, 36, 43, 44, 54, 64, 74, 84]
        seek(to: stops.first { $0 > second } ?? Self.duration)
    }
    func jump(to phase: Phase) {
        pause(); seek(to: phase == .navigation ? 5 : phase == .ride ? 44 : 64)
    }
    func selectPage(_ raw: UInt8) -> Bool { driver.manuallySelect(rawValue: raw) }

    /// Replay a bounded fixture to reach exactly the same state after any seek.
    /// No live clock/GPS/network is consulted; formal AppModel state is untouched.
    func seek(to value: Int) {
        second = min(Self.duration, max(0, value))
        let nav = MotoNavCoreBridge()
        nav.setNetworkStateName("online") // Local route availability, not a network claim.
        let destination = fix(at: totalM, second: 0).coordinate
        nav.beginNavigation(toLongitude: destination.longitudeDeg, latitude: destination.latitudeDeg)
        let first = fix(at: 0, second: 0)
        let commands = push(first, into: nav)
        if let request = commands.first(where: { $0.typeName == "request_route" }) {
            nav.acceptRoute(bridgeRoute(), requestID: request.requestID, receivedAtMs: Self.ms(0))
        }
        for t in 0...min(second, 43) { _ = push(fix(at: navigationOffset(t), second: t), into: nav) }
        snapshot = nav.snapshot
        ride = RideSession(); backtrack = nil
        if phase != .backtrack { returnRoute = nil }
        if phase != .navigation {
            ride.start(at: Self.epoch.addingTimeInterval(44))
            for t in 44...min(second, 64) {
                let fix = fix(at: rideOffset(t), second: t)
                ride.accept(fix, receivedAt: fix.timestamp)
            }
            // Idle NavCore with simulated fix feeds the existing Speed page.
            let speed = MotoNavCoreBridge()
            _ = push(fix(at: rideOffset(min(second,64)), second: second), into: speed)
            snapshot = speed.snapshot
        }
        if phase == .backtrack {
            if returnRoute == nil { returnRoute = try? BacktrackRoute.build(track: ride.track, sourceRideStartedAt: Self.epoch.addingTimeInterval(44)) }
        }
        if let route = returnRoute, phase == .backtrack {
            // Build once per replay; numeric geometry remains deterministic.
            var session = BacktrackSession(route: route)
            for t in 64...second {
                let offset = max(0, totalM * (1 - Double(t - 64) / 20))
                let fix = fix(at: offset, second: t, reversed: true)
                session.update(fix, at: fix.timestamp)
            }
            backtrack = session
        }
        _ = driver.update(navigation: phase == .navigation ? .init(snapshot: snapshot) : nil,
                          rideActive: phase != .navigation,
                          backtrack: backtrack?.component(paused: false))
        onFrame?()
    }
    private func push(_ fix: NavigationFix, into nav: MotoNavCoreBridge) -> [MotoNavCoreCommand] {
        nav.pushFixLongitude(fix.coordinate.longitudeDeg, latitude: fix.coordinate.latitudeDeg,
                             accuracyM: fix.horizontalAccuracyM, speedMPS: fix.speedMps ?? 0,
                             headingDeg: fix.courseDeg ?? .nan, timestampMs: UInt64(fix.timestamp.timeIntervalSince1970 * 1000))
    }
    func navigationOffset(_ t: Int) -> Double {
        if scenario != .rightLeft { return totalM * max(0, min(1, Double(t-5)/38)) }
        let frames: [(Int, Double)] = [(0,0),(5,0),(11,120),(14,170),(17,220),(20,270),(25,340),
                                      (30,410),(36,520),(43,totalM)]
        return Self.interpolate(t, frames)
    }
    func rideOffset(_ t: Int) -> Double {
        Self.interpolate(t, [(44,0),(54,cumulative[1]),(60,cumulative[max(2, route.count/2)]),(64,totalM)])
    }
    private static func interpolate(_ t: Int, _ frames: [(Int, Double)]) -> Double {
        for i in 1..<frames.count where t <= frames[i].0 {
            let a = frames[i-1], b = frames[i]
            return a.1 + (b.1 - a.1) * max(0, Double(t - a.0) / Double(b.0 - a.0))
        }
        return frames.last!.1
    }
    func fix(at offset: Double, second: Int, reversed: Bool = false) -> NavigationFix {
        let offset = min(totalM, max(0,offset))
        let i = (1..<cumulative.count).first { offset < cumulative[$0] } ?? route.count-1
        let a = route[i-1], b = route[i]
        let f = (offset-cumulative[i-1]) / (cumulative[i]-cumulative[i-1])
        let p = GCJ02Point(longitudeDeg: a.longitudeDeg+(b.longitudeDeg-a.longitudeDeg)*f,
                           latitudeDeg: a.latitudeDeg+(b.latitudeDeg-a.latitudeDeg)*f)
        let wgs = ChinaCoordinateTransform.gcj02ToWGS84(p)
        let bearing = atan2((b.longitudeDeg-a.longitudeDeg) * cos(p.latitudeDeg * .pi/180), b.latitudeDeg-a.latitudeDeg) * 180 / .pi
        let course = (bearing + (reversed ? 540 : 360)).truncatingRemainder(dividingBy: 360)
        let previous = reversed ? min(totalM,totalM*(1-Double(max(0,second-65))/20)) : second < 44 ? navigationOffset(max(0,second-1)) : rideOffset(max(44,second-1))
        let speed = abs(offset-previous)
        return .init(coordinate: wgs, horizontalAccuracyM: 2, speedMps: speed,
                     courseDeg: course, timestamp: Self.epoch.addingTimeInterval(Double(second)))
    }
    private static func ms(_ second: Int) -> UInt64 { UInt64(epoch.timeIntervalSince1970 * 1000) + UInt64(second) * 1000 }
    private func bridgeRoute() -> MotoNavRouteValue {
        let value = MotoNavRouteValue()
        value.routeID = "waymate-demo-\(scenario.rawValue)"
        value.totalDistanceM = totalM; value.totalDurationS = 43; value.generatedAtMs = Self.ms(0)
        value.polyline = route.map { p in
            let v = MotoNavPointValue(); v.latitudeDeg = p.latitudeDeg; v.longitudeDeg = p.longitudeDeg; return v
        }
        let actions = fixture.actions.enumerated().map { index, action in
            (UInt32(index+1),action.1,cumulative[action.0],action.2)
        } + [(UInt32(fixture.actions.count+1),"arrive",totalM,"到达目的地")]
        value.maneuvers = actions.map { id, type, offset, text in
            let v = MotoNavManeuverValue(); v.identifier = id; v.typeName = type; v.routeOffsetM = offset
            v.roadName = ""; v.instructionText = text; return v
        }
        value.traffic = []
        return value
    }
}
