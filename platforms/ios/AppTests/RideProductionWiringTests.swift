import MotoNavigationCore
import XCTest
@testable import Waymate

@MainActor
final class RideProductionWiringTests: XCTestCase {
    private let destination = WGS84Point(longitudeDeg: 117.13, latitudeDeg: 36.66)

    func testLifecycleRepeatedActionsAndLastRecordSurvivesNextStart() async throws {
        let source = ProductionRideSource()
        var now = Date()
        let start = now
        let model = AppModel(startsServices: false, locationSource: source, rideNow: { now })
        XCTAssertEqual(model.presentationDecision.primaryComponent, .idle)
        model.startRide(); model.startRide()
        XCTAssertEqual(model.rideSessionState, .active)
        XCTAssertEqual(source.starts, 1)
        XCTAssertEqual(model.presentationDecision.primaryComponent, .ride)
        now = start.addingTimeInterval(2)
        model.pauseRide(); model.pauseRide(); model.startRide()
        XCTAssertEqual(model.rideSessionState, .paused)
        XCTAssertEqual(model.rideElapsedTime, 2)
        XCTAssertNil(model.rideCurrentSpeed)
        XCTAssertEqual(model.presentationDecision.primaryComponent, .ride)
        now = start.addingTimeInterval(10)
        model.resumeRide(); model.resumeRide()
        XCTAssertEqual(model.rideSessionState, .active)
        now = start.addingTimeInterval(13)
        model.stopRide(); model.stopRide()
        let record = try XCTUnwrap(model.lastRideRecord)
        XCTAssertEqual(record.elapsedTime, 5)
        XCTAssertEqual(record, model.rideRecord)
        XCTAssertEqual(model.rideSessionState, .inactive)
        XCTAssertEqual(model.presentationDecision.primaryComponent, .idle)
        model.startRide()
        XCTAssertNil(model.rideRecord)
        XCTAssertEqual(model.lastRideRecord, record)
        model.stopRide()
    }

    func testActiveAndPausedNavigationStartsDoNotReplaceOrResumeRide() async {
        for paused in [false, true] {
            let source = ProductionRideSource()
            let model = AppModel(startsServices: false, locationSource: source)
            model.startRide()
            source.emit()
            let track = model.rideTrack
            if paused { model.pauseRide() }
            model.beginLiveNavigation(destination: destination, routeProvider: ProductionRideRoute())
            XCTAssertTrue(model.isNavigationActive)
            XCTAssertEqual(model.rideSessionState, paused ? .paused : .active)
            XCTAssertEqual(model.rideTrack, track)
            model.beginLiveNavigation(destination: destination, routeProvider: ProductionRideRoute())
            XCTAssertEqual(model.rideTrack, track)
            model.stopNavigation()
            XCTAssertTrue(model.rideActive)
            model.stopRide()
        }
    }

    func testAutomaticRideRollsBackOnAsynchronousLocationFailure() async {
        let source = ProductionRideSource()
        let model = AppModel(startsServices: false, locationSource: source)
        model.beginLiveNavigation(destination: destination, routeProvider: ProductionRideRoute())
        XCTAssertTrue(model.rideActive)
        source.failure?("GPS denied")
        XCTAssertFalse(model.rideActive)
        XCTAssertFalse(model.isNavigationActive)
        XCTAssertNil(model.lastRideRecord)
        XCTAssertEqual(model.navigationFailure, "GPS denied")
        XCTAssertEqual(source.stops, 1)
    }

    func testRepeatedRideStartCannotDisableAutomaticRollback() async {
        let source = ProductionRideSource()
        let model = AppModel(startsServices: false, locationSource: source)
        model.beginLiveNavigation(destination: destination, routeProvider: ProductionRideRoute())
        model.startRide(); model.startRide()
        source.failure?("Startup failed")
        XCTAssertFalse(model.rideActive)
        XCTAssertFalse(model.isNavigationActive)
        XCTAssertNil(model.lastRideRecord)
    }

    func testManualRideSurvivesAsynchronousNavigationLocationFailure() async {
        let source = ProductionRideSource()
        let model = AppModel(startsServices: false, locationSource: source)
        model.startRide()
        model.beginLiveNavigation(destination: destination, routeProvider: ProductionRideRoute())
        source.failure?("GPS denied")
        XCTAssertEqual(model.rideSessionState, .active)
        XCTAssertEqual(model.navigationFailure, "GPS denied")
        XCTAssertNil(model.lastRideRecord)
        model.stopNavigation(); model.stopRide()
    }

    func testMismatchedInitialResponseRollsBackAutomaticRide() async {
        let source = ProductionRideSource()
        let model = AppModel(startsServices: false, locationSource: source)
        model.beginLiveNavigation(destination: destination, routeProvider: ProductionRideRoute(mismatched: true))
        source.emit()
        await waitUntil { model.navigationFailure != nil }
        XCTAssertFalse(model.rideActive)
        XCTAssertFalse(model.isNavigationActive)
        XCTAssertNil(model.lastRideRecord)
    }

    func testInitialRouteFailureRollsBackOnlyAutomaticRide() async {
        for manual in [false, true] {
            let source = ProductionRideSource()
            let model = AppModel(startsServices: false, locationSource: source)
            if manual { model.startRide() }
            model.beginLiveNavigation(destination: destination, routeProvider: ProductionRideRoute(fails: true))
            source.emit()
            await waitUntil { model.navigationFailure != nil }
            XCTAssertEqual(model.rideActive, manual)
            XCTAssertNil(model.lastRideRecord)
            if !manual {
                XCTAssertFalse(model.isNavigationActive)
                XCTAssertTrue(model.rideTrack.isEmpty)
            }
            model.stopNavigation(); model.stopRide()
        }
    }

    func testRejectedRouteRollsBackAutomaticRide() async {
        let source = ProductionRideSource()
        let model = AppModel(startsServices: false, locationSource: source)
        model.beginLiveNavigation(destination: destination, routeProvider: ProductionRideRoute(invalid: true))
        source.emit()
        await waitUntil { model.navigationFailure != nil }
        XCTAssertFalse(model.rideActive)
        XCTAssertFalse(model.isNavigationActive)
        XCTAssertNil(model.lastRideRecord)
    }

    func testAcceptedRouteCommitsRideAndLaterFailureDoesNotRollBack() async {
        let source = ProductionRideSource()
        let model = AppModel(startsServices: false, locationSource: source)
        model.beginLiveNavigation(destination: destination, routeProvider: ProductionRideRoute())
        source.emit()
        await waitUntil { model.navigationComponentState.isNavigationValid }
        XCTAssertEqual(model.presentationDecision.primaryComponent, .navigation)
        source.failure?("GPS interrupted")
        XCTAssertTrue(model.rideActive)
        model.stopNavigation(); model.stopNavigation()
        XCTAssertTrue(model.rideActive)
        XCTAssertEqual(source.stops, 0)
        model.stopRide()
        XCTAssertNotNil(model.lastRideRecord)
        XCTAssertEqual(source.stops, 1)
    }

    func testEndRideDuringNavigationKeepsNavigationAndLocationRunning() async {
        let source = ProductionRideSource()
        let model = AppModel(startsServices: false, locationSource: source)
        model.beginLiveNavigation(destination: destination, routeProvider: ProductionRideRoute())
        model.stopRide(); model.stopRide()
        XCTAssertFalse(model.rideActive)
        XCTAssertNotNil(model.lastRideRecord)
        XCTAssertTrue(model.isNavigationActive)
        XCTAssertEqual(source.stops, 0)
        source.emit()
        await waitUntil { model.navigationComponentState.isNavigationValid }
        model.stopNavigation()
        XCTAssertEqual(source.stops, 1)
    }

    func testRollbackPreservesPreviouslyCompletedRecord() async throws {
        let source = ProductionRideSource()
        let model = AppModel(startsServices: false, locationSource: source)
        model.startRide(); model.stopRide()
        let previous = try XCTUnwrap(model.lastRideRecord)
        model.beginLiveNavigation(destination: destination, routeProvider: ProductionRideRoute(fails: true))
        source.emit()
        await waitUntil { model.navigationFailure != nil }
        XCTAssertEqual(model.lastRideRecord, previous)
        XCTAssertFalse(model.rideActive)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Navigation callback did not arrive")
    }
}

@MainActor
private final class ProductionRideSource: NavigationLocationSource {
    var starts = 0
    var stops = 0
    var failure: (@MainActor (String) -> Void)?
    private var onFix: (@MainActor (NavigationFix) -> Void)?
    func start(onFix: @escaping @MainActor (NavigationFix) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) throws {
        starts += 1
        self.onFix = onFix
        failure = onFailure
    }
    func stop() { stops += 1; onFix = nil; failure = nil }
    func emit() {
        onFix?(.init(coordinate: .init(longitudeDeg: 117.12, latitudeDeg: 36.67),
                     horizontalAccuracyM: 3, speedMps: nil, timestamp: Date()))
    }
}

private struct ProductionRideRoute: NavigationRouteProviding {
    var fails = false
    var invalid = false
    var mismatched = false
    func route(for request: RouteRequest) async throws -> RouteEnvelope {
        if fails { throw NavigationSourceError.unavailable("Initial route failed") }
        return RouteEnvelope(requestID: mismatched ? request.requestID &+ 1 : request.requestID, route: RoutePlan(
            routeID: "production-wiring-test", provider: "test", generatedAtMs: 1,
            totalDistanceM: 1_500, totalDurationS: 360,
            polyline: invalid ? [] : [.init(longitudeDeg: 117.12, latitudeDeg: 36.67),
                                     .init(longitudeDeg: 117.13, latitudeDeg: 36.66)],
            maneuvers: [], traffic: []))
    }
}
