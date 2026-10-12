import MotoNavigationCore
import XCTest
@testable import Waymate

@MainActor
final class CompetitionDemoTests: XCTestCase {
    func testFixedOfflineNavigationFramesUseSharedNavCoreAndGeometry() {
        let demo = CompetitionDemo()
        for (second, direction, maneuver, distance) in [(5,"东","right",320.0),(11,"东","right",200.0),
                                                       (14,"东","right",150.0),(17,"东","right",100.0),(20,"东","right",50.0),
                                                       (25,"南","left",160.0),(36,"东","arrive",100.0)] {
            demo.seek(to: second)
            XCTAssertEqual(demo.snapshot.stateName, "navigating", "at \(second)")
            XCTAssertEqual(demo.snapshot.routeDirection, direction, "at \(second)")
            XCTAssertEqual(demo.snapshot.maneuverTypeName, maneuver, "at \(second)")
            XCTAssertEqual(demo.snapshot.distanceToManeuverM, distance, accuracy: 2, "at \(second)")
            XCTAssertFalse(demo.snapshot.gnssStale)
            XCTAssertFalse(demo.snapshot.offRoute)
        }
    }
    func testRideAndBacktrackUseTheSameRecordedTrail() {
        let demo = CompetitionDemo()
        demo.seek(to: 54)
        let mid = demo.ride.distance
        XCTAssertGreaterThan(demo.ride.track.count, 2)
        demo.seek(to: 64)
        XCTAssertGreaterThan(demo.ride.distance, mid)
        let start = demo.backtrack!.progress.remainingDistance
        let identity = demo.backtrack!.route.id
        let trail = demo.ride.track
        demo.seek(to: 74)
        XCTAssertEqual(demo.backtrack!.route.id, identity)
        XCTAssertEqual(demo.ride.track, trail)
        XCTAssertLessThan(demo.backtrack!.progress.remainingDistance, start)
        demo.seek(to: 84)
        XCTAssertTrue(demo.backtrack!.progress.arrived)
        XCTAssertEqual(demo.page, .backtrack)
        XCTAssertTrue(demo.completed)
        XCTAssertFalse(demo.ride.track.isEmpty)
    }
    func testPauseReplayNextJumpAndBoundaries() async throws {
        let demo = CompetitionDemo()
        XCTAssertFalse(demo.running)
        demo.play(); demo.pause()
        let before = demo.second
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(demo.second, before)
        demo.next(); XCTAssertEqual(demo.second, 5)
        let distance = demo.snapshot.distanceToManeuverM
        demo.jump(to: .ride); XCTAssertEqual(demo.page, .speed)
        demo.jump(to: .backtrack); XCTAssertEqual(demo.page, .backtrack)
        demo.jump(to: .navigation); XCTAssertEqual(demo.snapshot.distanceToManeuverM, distance)
        demo.replay(); demo.pause(); XCTAssertEqual(demo.second, 0)
        demo.seek(to: 200); XCTAssertEqual(demo.second, 84)
        demo.seek(to: -1); XCTAssertEqual(demo.second, 0)
    }
    func testAllAutomaticStepsReachTheEndWithoutServices() {
        let demo = CompetitionDemo()
        for _ in 0..<CompetitionDemo.duration { demo.advance() }
        XCTAssertEqual(demo.second, 84)
        XCTAssertTrue(demo.backtrack!.progress.arrived)
        XCTAssertFalse(demo.running)
    }
    func testAllRouteScenariosRemainBoundedAndReachArrivalWithoutServices() throws {
        let demo = CompetitionDemo()
        for scenario in CompetitionDemo.Scenario.allCases {
            demo.selectScenario(scenario)
            XCTAssertEqual(demo.second, 5)
            XCTAssertFalse(demo.running)
            XCTAssertTrue(demo.snapshot.hasRouteView)
            XCTAssertLessThanOrEqual(demo.snapshot.miniMapPoints.count, 24)
            XCTAssertEqual(demo.snapshot.routeViewPoints.count, demo.snapshot.miniMapPoints.count)
            let expected = scenario == .left ? "left" : scenario == .straight ? "continue" : scenario == .sCurve ? "slight_right" : scenario == .uTurn ? "u_turn_right" : "right"
            XCTAssertEqual(demo.snapshot.maneuverTypeName, expected)
            let codec = MotoBLEProtocolCodec(maximumFrameSize: 256)
            let frames = try codec.encodeRouteGeometry(from: demo.snapshot)
            XCTAssertFalse(frames.isEmpty)
            XCTAssertTrue(frames.allSatisfy { $0.count <= 256 })
            demo.seek(to: 42)
            XCTAssertFalse(demo.snapshot.offRoute)
            demo.seek(to: 43)
            XCTAssertEqual(demo.snapshot.stateName, "arrived", "\(scenario)")
        }
    }
    func testOwnerNeverReplacesProductionStateOrPersistsDemoHistory() async throws {
        let location = DemoIsolationLocation()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DemoIsolation-\(UUID()).json")
        let store = RideStore(fileURL: url)
        let model = AppModel(startsServices: false, locationSource: location, rideStore: store)
        await model.waitForRidePersistence()
        let snapshot = model.navigation
        let history = model.rideHistory
        let preferences = UserDefaults.standard.dictionaryRepresentation()
        model.startDemoNavigation()
        let demo = try XCTUnwrap(model.competitionDemo)
        for _ in 0..<CompetitionDemo.duration { demo.advance() }
        XCTAssertTrue(model.navigation === snapshot)
        XCTAssertFalse(model.isNavigationActive)
        XCTAssertFalse(model.rideActive)
        XCTAssertNil(model.backtrackSession)
        XCTAssertEqual(model.rideHistory, history)
        XCTAssertEqual(location.starts, 0)
        let stored = try await store.load()
        XCTAssertEqual(stored, history)
        XCTAssertEqual(UserDefaults.standard.dictionaryRepresentation() as NSDictionary, preferences as NSDictionary)
        model.exitCompetitionDemo()
        XCTAssertNil(model.competitionDemo)
        XCTAssertEqual(model.presentationDriver.selectedPage, .navigation)
        XCTAssertTrue(model.navigation === snapshot)
    }
    func testRealRideBlocksDemoEntryAndIsPreserved() {
        let model = AppModel(startsServices: false, locationSource: DemoIsolationLocation())
        model.startRide()
        XCTAssertTrue(model.rideActive)
        XCTAssertFalse(model.canEnterCompetitionDemo)
        model.startDemoNavigation()
        XCTAssertNil(model.competitionDemo)
        XCTAssertTrue(model.rideActive)
    }
}

@MainActor
private final class DemoIsolationLocation: NavigationLocationSource {
    var starts = 0
    func start(onFix: @escaping @MainActor (NavigationFix) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) throws { starts += 1 }
    func stop() {}
}
