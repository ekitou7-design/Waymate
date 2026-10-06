import XCTest
@testable import Waymate

final class NavigationReadoutTests: XCTestCase {
    func testNormalManeuverAndUnknownFallbackUseSource() {
        let snapshot = ReadoutSnapshot()
        var readout = project(snapshot)
        XCTAssertEqual(readout.status, "NAVIGATION")
        XCTAssertTrue(readout.canShowManeuver)
        XCTAssertEqual(readout.maneuver.label, "右转")
        snapshot.type = "roundabout"
        XCTAssertEqual(project(snapshot).maneuver.label, "环岛 · 第 2 出口")
        snapshot.type = "unrecognized"
        readout = project(snapshot)
        XCTAssertEqual(readout.maneuver.symbol, "questionmark")
    }

    func testWarningsNeverPresentNormalLiveManeuver() {
        let snapshot = ReadoutSnapshot()
        snapshot.stale = true
        XCTAssertEqual(project(snapshot).status, "LOCATION STALE")
        XCTAssertFalse(project(snapshot).canShowManeuver)
        snapshot.stale = false
        snapshot.usable = false
        XCTAssertEqual(project(snapshot).status, "WAITING FOR GPS")
        XCTAssertFalse(project(snapshot).canShowManeuver)
        snapshot.usable = true
        snapshot.phase = "rerouting"
        XCTAssertEqual(project(snapshot).status, "REROUTING")
        XCTAssertFalse(project(snapshot).canShowManeuver)
        snapshot.phase = "navigating"
        snapshot.off = true
        XCTAssertEqual(project(snapshot).status, "OFF ROUTE")
        XCTAssertFalse(project(snapshot).canShowManeuver)
        XCTAssertEqual(project(snapshot, failure: "Route failed").status, "NAVIGATION UNAVAILABLE")
        XCTAssertFalse(project(snapshot, failure: "Route failed").canShowManeuver)
    }

    func testArrivalAndMissingRouteKeepAuthoritativeSemantics() {
        let snapshot = ReadoutSnapshot()
        snapshot.phase = "arrived"
        snapshot.stale = true
        XCTAssertEqual(project(snapshot).status, "ARRIVED")
        XCTAssertFalse(project(snapshot).canShowManeuver)
        snapshot.phase = "navigating"
        snapshot.stale = false
        snapshot.route = ""
        XCTAssertEqual(project(snapshot).status, "ROUTE LOADING")
        XCTAssertFalse(project(snapshot).canShowManeuver)
    }

    private func project(_ snapshot: ReadoutSnapshot, failure: String? = nil) -> NavigationReadout {
        NavigationReadout(state: NavigationComponentState(snapshot: snapshot), failure: failure)
    }
}

private final class ReadoutSnapshot: MotoNavCoreSnapshot {
    var phase = "navigating"
    var route = "readout-test"
    var type = "right"
    var stale = false
    var usable = true
    var off = false
    override var stateName: String { phase }
    override var routeID: String { route }
    override var maneuverTypeName: String { type }
    override var hasNextManeuver: Bool { true }
    override var roundaboutExit: UInt8 { 2 }
    override var gnssStale: Bool { stale }
    override var hasUsableFix: Bool { usable }
    override var offRoute: Bool { off }
}
