import MotoNavigationCore
import XCTest
@testable import Waymate

final class RideSessionTests: XCTestCase {
    func testInitialStateIsInactive() {
        let session = RideSession()
        XCTAssertEqual(session.state, .inactive)
        XCTAssertFalse(session.isActive)
    }

    func testStartMakesSessionActive() {
        var session = RideSession()
        session.start()
        XCTAssertEqual(session.state, .active)
        XCTAssertTrue(session.isActive)
    }

    func testRepeatedStartIsIdempotent() {
        var session = RideSession()
        session.start()
        let active = session
        session.start()
        XCTAssertEqual(session, active)
    }

    func testStopMakesSessionInactive() {
        var session = RideSession()
        session.start()
        session.stop()
        XCTAssertEqual(session.state, .inactive)
        XCTAssertFalse(session.isActive)
    }

    func testRepeatedStopIsIdempotent() {
        var session = RideSession()
        let inactive = session
        session.stop()
        session.stop()
        XCTAssertEqual(session, inactive)
    }

    func testSameCommandsProduceDeterministicStateAndProjection() {
        var first = RideSession()
        var second = RideSession()
        for start in [false, true, true, false, false, true, false, true] {
            if start {
                first.start(at: Date(timeIntervalSince1970: 100))
                second.start(at: Date(timeIntervalSince1970: 100))
            } else {
                first.stop(at: Date(timeIntervalSince1970: 200))
                second.stop(at: Date(timeIntervalSince1970: 200))
            }
            XCTAssertEqual(first, second)
            XCTAssertEqual(first.state, start ? .active : .inactive)
            XCTAssertEqual(first.isActive, start)
        }
    }

    @MainActor
    func testNavigationStartAndStopDoNotStartRide() async {
        let session = RideSession()
        let runtime = makeRuntime()
        defer { runtime.stop() }
        XCTAssertTrue(runtime.start(destination: destination))
        XCTAssertEqual(session.state, .inactive)
        runtime.stop()
        XCTAssertEqual(session.state, .inactive)
    }

    @MainActor
    func testActiveRideCanExistWithoutNavigationAndSurvivesNavigationStop() async {
        var session = RideSession()
        session.start()
        XCTAssertTrue(session.isActive)
        let runtime = makeRuntime()
        defer { runtime.stop() }
        XCTAssertTrue(runtime.start(destination: destination))
        XCTAssertTrue(session.isActive)
        runtime.stop()
        XCTAssertTrue(session.isActive)
    }

    @MainActor
    func testNavigationStartFailureDoesNotStopActiveRide() async {
        var session = RideSession()
        session.start()
        let runtime = makeRuntime(failStart: true)
        defer { runtime.stop() }
        XCTAssertFalse(runtime.start(destination: destination))
        XCTAssertTrue(session.isActive)
    }

    @MainActor
    func testRideCommandsDoNotStartOrStopNavigation() async {
        var session = RideSession()
        let location = RideTestLocationSource()
        let runtime = SharedNavigationRuntime(locationSource: location, routeProvider: UnusedRideTestRouteProvider())
        defer { runtime.stop() }
        session.start()
        XCTAssertFalse(location.isRunning)
        XCTAssertTrue(runtime.start(destination: destination))
        session.stop()
        XCTAssertTrue(location.isRunning)
        session.start()
        XCTAssertTrue(location.isRunning)
    }

    func testCoordinatorConsumesProjectionWithoutMutatingSession() {
        var session = RideSession()
        let now = ContinuousClock().now
        func evaluate() -> PresentationDecision {
            PresentationCoordinator.evaluate(
                input: .init(navigation: nil, rideActive: session.isActive, mediaInteraction: nil),
                now: now
            )
        }
        XCTAssertEqual(evaluate().primaryComponent, .idle)
        session.start()
        let active = session
        let decision = evaluate()
        XCTAssertEqual(decision.primaryComponent, .ride)
        XCTAssertEqual(decision.reason, .rideHome)
        XCTAssertEqual(decision, evaluate())
        XCTAssertEqual(session, active)
        session.stop()
        XCTAssertEqual(evaluate().primaryComponent, .idle)
    }

    @MainActor
    func testAppModelExposesOnlySessionProjectionsAndExplicitCommands() async {
        let model = AppModel(startsServices: false, locationSource: RideTestLocationSource())
        XCTAssertEqual(model.rideSessionState, .inactive)
        XCTAssertFalse(model.rideActive)
        model.startRide()
        model.startRide()
        XCTAssertEqual(model.rideSessionState, .active)
        XCTAssertTrue(model.rideActive)
        XCTAssertFalse(model.isNavigationActive)
        model.stopRide()
        model.stopRide()
        XCTAssertEqual(model.rideSessionState, .inactive)
        XCTAssertFalse(model.rideActive)
        XCTAssertFalse(model.isNavigationActive)
    }

    @MainActor
    func testAppModelNavigationCommandsDoNotControlRide() async {
        let model = AppModel(startsServices: false, locationSource: RideTestLocationSource())
        // No destination/preview: a rejected start must not create a Ride.
        model.startNavigation()
        XCTAssertFalse(model.isNavigationActive)
        XCTAssertFalse(model.rideActive)
        model.startRide()
        model.startNavigation()
        XCTAssertFalse(model.isNavigationActive)
        XCTAssertTrue(model.rideActive)
        model.stopNavigation()
        XCTAssertTrue(model.rideActive)
        model.stopRide()
        model.stopNavigation()
        XCTAssertFalse(model.rideActive)
    }

    private var destination: WGS84Point {
        WGS84Point(longitudeDeg: 117.12, latitudeDeg: 36.67)
    }

    @MainActor
    private func makeRuntime(failStart: Bool = false) -> SharedNavigationRuntime {
        SharedNavigationRuntime(
            locationSource: RideTestLocationSource(failStart: failStart),
            routeProvider: UnusedRideTestRouteProvider()
        )
    }
}

/// No fixes are emitted, so these lifecycle checks need neither GPS nor network.
@MainActor
private final class RideTestLocationSource: NavigationLocationSource {
    private let failStart: Bool
    private(set) var isRunning = false

    init(failStart: Bool = false) { self.failStart = failStart }

    func start(
        onFix: @escaping @MainActor (NavigationFix) -> Void,
        onFailure: @escaping @MainActor (String) -> Void
    ) throws {
        if failStart { throw NavigationSourceError.permissionDenied }
        isRunning = true
    }

    func stop() { isRunning = false }
}

private struct UnusedRideTestRouteProvider: NavigationRouteProviding {
    func route(for request: RouteRequest) async throws -> RouteEnvelope {
        XCTFail("Lifecycle checks must not request a route")
        throw NavigationSourceError.unavailable("No fix supplied")
    }
}
