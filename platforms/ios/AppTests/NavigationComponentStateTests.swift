import XCTest
@testable import Waymate

final class NavigationComponentStateTests: XCTestCase {
    func testInitialBridgeSnapshotHasNoRouteOrEstimates() {
        let state = NavigationComponentState(snapshot: MotoNavCoreBridge().snapshot)
        XCTAssertEqual(state.phase, "idle")
        XCTAssertNil(state.routeIdentity)
        XCTAssertFalse(state.isNavigationValid)
        XCTAssertNil(state.nextManeuver)
        XCTAssertNil(state.remainingDistanceM)
        XCTAssertNil(state.remainingDurationS)
        XCTAssertFalse(state.arrived)
    }

    func testNormalNavigationProjectsRouteAndPhase() {
        let state = project()
        XCTAssertEqual(state.phase, "navigating")
        XCTAssertEqual(state.routeIdentity, "route-1")
        XCTAssertEqual(state.routeGeneration, 1)
        XCTAssertTrue(state.isNavigationValid)
        XCTAssertEqual(state.locationValidity, .init(hasUsableFix: true, isStale: false))
    }

    func testManeuverProjectsIdentityRoadInstructionAndExit() {
        let state = project()
        XCTAssertEqual(state.nextManeuver, .init(id: 42, typeName: "roundabout", roundaboutExit: 2))
        XCTAssertEqual(state.maneuverRoadName, "测试道路")
        XCTAssertEqual(state.instruction, "从第二个出口驶出")
    }

    func testDistanceToManeuverPreservesMetersIncludingZero() {
        let snapshot = ProjectionSnapshot()
        XCTAssertEqual(NavigationComponentState(snapshot: snapshot).distanceToManeuverM, 125.5)
        snapshot.distance = 0
        XCTAssertEqual(NavigationComponentState(snapshot: snapshot).distanceToManeuverM, 0)
    }

    func testRemainingDistanceAndDurationPreserveSourceValues() {
        let state = project()
        XCTAssertEqual(state.remainingDistanceM, 2_450.5)
        XCTAssertEqual(state.remainingDurationS, 780)
    }

    func testOffRouteDoesNotInventReroutingPhase() {
        let snapshot = ProjectionSnapshot()
        snapshot.deviated = true
        let state = NavigationComponentState(snapshot: snapshot)
        XCTAssertTrue(state.offRoute)
        XCTAssertEqual(state.phase, "navigating")
    }

    func testArrivedAndZeroEstimatesArePreserved() {
        let snapshot = ProjectionSnapshot()
        snapshot.phase = "arrived"
        snapshot.remainingDistance = 0
        snapshot.remainingDuration = 0
        let state = NavigationComponentState(snapshot: snapshot)
        XCTAssertTrue(state.arrived)
        XCTAssertTrue(state.isNavigationValid)
        XCTAssertEqual(state.remainingDistanceM, 0)
        XCTAssertEqual(state.remainingDurationS, 0)
    }

    func testInvalidAndStaleLocationRemainIndependentFacts() {
        let snapshot = ProjectionSnapshot()
        for usable in [false, true] {
            for stale in [false, true] {
                snapshot.usable = usable
                snapshot.stale = stale
                let state = NavigationComponentState(snapshot: snapshot)
                XCTAssertEqual(state.locationValidity.hasUsableFix, usable)
                XCTAssertEqual(state.locationValidity.isStale, stale)
                XCTAssertEqual(state.phase, "navigating")
            }
        }
    }

    func testRouteGenerationUpdateChangesValueWithoutMutatingPreviousProjection() {
        let snapshot = ProjectionSnapshot()
        let previous = NavigationComponentState(snapshot: snapshot)
        snapshot.generation = 2
        let next = NavigationComponentState(snapshot: snapshot)
        XCTAssertEqual(previous.routeGeneration, 1)
        XCTAssertEqual(next.routeGeneration, 2)
        XCTAssertEqual(next.routeIdentity, previous.routeIdentity)
        XCTAssertNotEqual(previous, next)
        XCTAssertEqual(next, NavigationComponentState(snapshot: snapshot))
    }

    func testMissingManeuverHidesRetainedSourceFields() {
        let snapshot = ProjectionSnapshot()
        snapshot.maneuverAvailable = false
        let state = NavigationComponentState(snapshot: snapshot)
        XCTAssertNil(state.nextManeuver)
        XCTAssertNil(state.distanceToManeuverM)
        XCTAssertNil(state.maneuverRoadName)
        XCTAssertNil(state.instruction)
    }

    func testEmptyTextStaysUnavailableWithoutSynthesizedInstruction() {
        let snapshot = ProjectionSnapshot()
        snapshot.road = ""
        snapshot.text = ""
        let state = NavigationComponentState(snapshot: snapshot)
        XCTAssertNotNil(state.nextManeuver)
        XCTAssertNil(state.maneuverRoadName)
        XCTAssertNil(state.instruction)
    }

    func testMissingRouteHidesNumbersAndManeuverEvenInNavigationPhase() {
        let snapshot = ProjectionSnapshot()
        snapshot.route = ""
        let state = NavigationComponentState(snapshot: snapshot)
        XCTAssertFalse(state.isNavigationValid)
        XCTAssertNil(state.remainingDistanceM)
        XCTAssertNil(state.remainingDurationS)
        XCTAssertNil(state.nextManeuver)
        XCTAssertNil(state.distanceToManeuverM)
        XCTAssertNil(state.maneuverRoadName)
        XCTAssertNil(state.instruction)
    }

    func testPhaseNamesArePreservedWithoutSessionReducerTranslation() {
        let snapshot = ProjectionSnapshot()
        for phase in ["idle", "acquiring", "planning", "navigating", "rerouting", "arrived"] {
            snapshot.phase = phase
            let state = NavigationComponentState(snapshot: snapshot)
            XCTAssertEqual(state.phase, phase)
            XCTAssertEqual(state.arrived, phase == "arrived")
            XCTAssertEqual(state.isNavigationValid, ["navigating", "rerouting", "arrived"].contains(phase))
        }
    }

    private func project() -> NavigationComponentState {
        NavigationComponentState(snapshot: ProjectionSnapshot())
    }
}

/// Getter-only Bridge fixture: no navigation runtime, location, BLE or UI effects.
private final class ProjectionSnapshot: MotoNavCoreSnapshot {
    var phase = "navigating"
    var route = "route-1"
    var generation: UInt32 = 1
    var maneuverAvailable = true
    var distance = 125.5
    var road = "测试道路"
    var text = "从第二个出口驶出"
    var remainingDistance = 2_450.5
    var remainingDuration: UInt32 = 780
    var deviated = false
    var usable = true
    var stale = false

    override var stateName: String { phase }
    override var routeID: String { route }
    override var routeGeneration: UInt32 { generation }
    override var hasNextManeuver: Bool { maneuverAvailable }
    override var maneuverID: UInt32 { 42 }
    override var maneuverTypeName: String { "roundabout" }
    override var roundaboutExit: UInt8 { 2 }
    override var distanceToManeuverM: Double { distance }
    override var roadName: String { road }
    override var instructionText: String { text }
    override var remainingDistanceM: Double { remainingDistance }
    override var remainingDurationS: UInt32 { remainingDuration }
    override var offRoute: Bool { deviated }
    override var hasUsableFix: Bool { usable }
    override var gnssStale: Bool { stale }
}
