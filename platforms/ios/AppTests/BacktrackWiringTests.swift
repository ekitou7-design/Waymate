import MotoNavigationCore
import XCTest
@testable import Waymate

@MainActor
final class BacktrackWiringTests: XCTestCase {
    private typealias T = BacktrackTestTrail
    private var now = BacktrackTestTrail.start
    private func model(_ source: BacktrackWiringSource, driver: PresentationDriver? = nil) -> AppModel {
        AppModel(startsServices: false, locationSource: source, rideNow: { self.now }, presentationDriver: driver)
    }
    private func outward(_ model: AppModel, _ source: BacktrackWiringSource) {
        model.startRide()
        for i in 0...10 {
            now = T.start.addingTimeInterval(Double(i) * 2)
            source.emit(T.fix(Double(i) * 10, time: Double(i) * 2))
        }
        XCTAssertTrue(model.backtrackTrailReady)
    }
    func testInactiveInsufficientAndPausedCannotStartOrResume() async {
        let source = BacktrackWiringSource(), model = model(BacktrackWiringSource())
        model.startBacktrack()
        XCTAssertFalse(model.isBacktrackActive)
        let active = self.model(source)
        active.startRide(); active.startBacktrack()
        XCTAssertFalse(active.isBacktrackActive)
        outward(active, source)
        active.pauseRide(); active.startBacktrack()
        XCTAssertEqual(active.rideSessionState, .paused)
        XCTAssertFalse(active.isBacktrackActive)
        XCTAssertEqual(active.backtrackUnavailableReason, "Resume Ride to start Backtrack")
        active.stopRide(); await active.waitForRidePersistence()
    }
    func testStartRepeatedStartEndRepeatedEndKeepsSingleRideAndSource() async throws {
        let source = BacktrackWiringSource(), model = model(source)
        outward(model, source)
        let track = model.rideTrack
        let distance = model.rideDistance
        model.startBacktrack()
        let routeID = try XCTUnwrap(model.backtrackSession?.route.id)
        model.startBacktrack()
        XCTAssertEqual(model.backtrackSession?.route.id, routeID)
        XCTAssertEqual(model.rideTrack, track)
        XCTAssertEqual(source.starts, 1)
        XCTAssertEqual(model.presentationDecision.primaryComponent, .backtrack)
        model.endBacktrack(); model.endBacktrack()
        XCTAssertTrue(model.rideActive)
        XCTAssertEqual(model.rideDistance, distance)
        XCTAssertEqual(source.stops, 0)
        XCTAssertEqual(model.presentationDecision.primaryComponent, .ride)
        model.stopRide(); await model.waitForRidePersistence()
    }
    func testSnapshotFixedWhileReturnRideContinuesAndFullRecordPersists() async throws {
        let source = BacktrackWiringSource(), model = model(source)
        outward(model, source)
        model.startBacktrack()
        let route = try XCTUnwrap(model.backtrackSession?.route)
        for i in 1...10 {
            now = T.start.addingTimeInterval(20 + Double(i) * 2)
            source.emit(T.fix(100 - Double(i) * 10, time: 20 + Double(i) * 2))
        }
        XCTAssertTrue(model.backtrackSession?.progress.arrived == true)
        XCTAssertTrue(model.rideActive)
        XCTAssertEqual(model.rideTrack.count, 21)
        XCTAssertEqual(model.backtrackSession?.route, route)
        model.stopRide(); await model.waitForRidePersistence()
        XCTAssertFalse(model.isBacktrackActive)
        let record = try XCTUnwrap(model.lastRideRecord)
        XCTAssertEqual(record.track.count, 21)
        XCTAssertEqual(record.distance, 200, accuracy: 1)
        XCTAssertEqual(model.rideHistory.first?.track, record.track)
    }
    func testPausedBacktrackStopsGuidanceWithoutSecondLocationOwner() async {
        let source = BacktrackWiringSource(), model = model(source)
        outward(model, source); model.startBacktrack()
        model.pauseRide()
        XCTAssertTrue(model.isBacktrackActive)
        XCTAssertTrue(model.backtrackComponentState?.paused == true)
        XCTAssertNil(model.backtrackSession?.progress.targetBearing)
        XCTAssertEqual(source.stops, 1)
        model.resumeRide()
        XCTAssertEqual(source.starts, 2)
        XCTAssertEqual(model.backtrackSession?.progress.locationValidity, .waiting)
        now = now.addingTimeInterval(2)
        source.emit(T.fix(90, time: 22))
        XCTAssertEqual(model.backtrackSession?.progress.locationValidity, .usable)
        model.stopRide(); await model.waitForRidePersistence()
    }
    func testNavigationConflictCancelPreservesBothRideAndOldNavigation() async {
        let source = BacktrackWiringSource(), model = model(source)
        outward(model, source)
        model.beginLiveNavigation(destination: T.point(200), routeProvider: BacktrackWiringRoute())
        model.startBacktrack()
        XCTAssertEqual(model.guidanceConflict, .startBacktrack)
        XCTAssertTrue(model.isNavigationActive)
        XCTAssertFalse(model.isBacktrackActive)
        model.cancelGuidanceSwitch()
        XCTAssertTrue(model.isNavigationActive)
        model.stopNavigation(); model.stopRide(); await model.waitForRidePersistence()
    }
    func testNavigationConflictConfirmationEndsNavigationThenStartsBacktrack() async {
        let source = BacktrackWiringSource(), model = model(source)
        outward(model, source)
        model.beginLiveNavigation(destination: T.point(200), routeProvider: BacktrackWiringRoute())
        model.startBacktrack(); model.confirmGuidanceSwitch()
        XCTAssertFalse(model.isNavigationActive)
        XCTAssertTrue(model.isBacktrackActive)
        XCTAssertTrue(model.rideActive)
        XCTAssertEqual(source.starts, 1)
        XCTAssertEqual(source.stops, 0)
        XCTAssertEqual(model.presentationDecision.primaryComponent, .backtrack)
        model.stopRide(); await model.waitForRidePersistence()
    }
    func testPauseWhileConfirmationOpenDoesNotEndNavigation() async {
        let source = BacktrackWiringSource(), model = model(source)
        outward(model, source)
        model.beginLiveNavigation(destination: T.point(200), routeProvider: BacktrackWiringRoute())
        model.startBacktrack(); model.pauseRide(); model.confirmGuidanceSwitch()
        XCTAssertTrue(model.isNavigationActive)
        XCTAssertFalse(model.isBacktrackActive)
        XCTAssertEqual(model.rideSessionState, .paused)
        model.stopNavigation(); model.stopRide(); await model.waitForRidePersistence()
    }
    func testStartLiveNavigationRequiresConfirmationDuringBacktrack() async {
        let source = BacktrackWiringSource(), model = model(source)
        outward(model, source); model.startBacktrack()
        let snapshot = model.backtrackSession
        model.beginLiveNavigation(destination: T.point(200), routeProvider: BacktrackWiringRoute())
        XCTAssertEqual(model.guidanceConflict, .startNavigation)
        XCTAssertFalse(model.isNavigationActive)
        XCTAssertEqual(model.backtrackSession, snapshot)
        model.cancelGuidanceSwitch()
        XCTAssertTrue(model.isBacktrackActive)
        model.beginLiveNavigation(destination: T.point(200), routeProvider: BacktrackWiringRoute())
        model.confirmGuidanceSwitch()
        XCTAssertFalse(model.isBacktrackActive)
        XCTAssertTrue(model.isNavigationActive)
        XCTAssertTrue(model.rideActive)
        XCTAssertEqual(source.starts, 1)
        model.stopNavigation(); model.stopRide(); await model.waitForRidePersistence()
    }
    func testDemoAlsoRequiresConfirmationAndEndRideCancelsPendingSwitch() async {
        let source = BacktrackWiringSource(), model = model(source)
        outward(model, source); model.startBacktrack(); model.startDemoNavigation()
        XCTAssertEqual(model.guidanceConflict, .startNavigation)
        XCTAssertFalse(model.isDemoActive)
        model.stopRide()
        XCTAssertNil(model.guidanceConflict)
        model.confirmGuidanceSwitch()
        XCTAssertFalse(model.isNavigationActive)
        await model.waitForRidePersistence()
    }
    func testLocationFailureInvalidatesGuidanceButKeepsRideAndRoute() async {
        let source = BacktrackWiringSource(), model = model(source)
        outward(model, source); model.startBacktrack()
        let route = model.backtrackSession?.route
        source.failure?("GPS unavailable")
        XCTAssertEqual(model.backtrackSession?.progress.locationValidity, .unavailable)
        XCTAssertNil(model.backtrackSession?.progress.targetBearing)
        XCTAssertEqual(model.backtrackSession?.route, route)
        XCTAssertTrue(model.rideActive)
        model.stopRide(); await model.waitForRidePersistence()
    }
}

@MainActor
final class BacktrackPresentationTests: XCTestCase {
    private var now = ContinuousClock().now
    private let routeID = UUID()
    private var pages: [RoundDisplayPage] = []
    private func state(off: Bool = false, event: String? = nil, paused: Bool = false,
                       validity: BacktrackLocationValidity = .usable, arrived: Bool = false) -> BacktrackComponentState {
        .init(routeIdentity: routeID, offTrack: off, arrived: arrived, paused: paused,
              locationValidity: validity, urgentEventIdentity: event)
    }
    private func driver() -> PresentationDriver {
        let d = PresentationDriver(now: { self.now }, schedulesExpiry: false)
        d.onSelection = { self.pages.append($0) }
        return d
    }
    func testBacktrackIsIndependentPrimaryWithExplicitV1SpeedFallback() {
        let d = driver()
        d.update(navigation: nil, rideActive: true, backtrack: state())
        XCTAssertEqual(d.currentDecision.primaryComponent, .backtrack)
        XCTAssertEqual(d.currentDecision.reason, .backtrackHome)
        XCTAssertEqual(d.selectedPage, .speed)
        XCTAssertEqual(RoundDisplayPage.allCases.map(\.rawValue), [0, 1, 2, 3])
    }
    func testManualCompassStaysAcrossOrdinaryUpdatesAndNewOffTrackReclaimsOnce() {
        let d = driver()
        d.update(navigation: nil, rideActive: true, backtrack: state())
        d.manuallySelect(rawValue: 2)
        for _ in 0..<100 { d.update(navigation: nil, rideActive: true, backtrack: state()) }
        XCTAssertEqual(pages, [.speed, .compass])
        d.update(navigation: nil, rideActive: true, backtrack: state(off: true, event: "off-1"))
        XCTAssertEqual(pages, [.speed, .compass, .speed])
        d.manuallySelect(rawValue: 2)
        for _ in 0..<100 { d.update(navigation: nil, rideActive: true, backtrack: state(off: true, event: "off-1")) }
        XCTAssertEqual(d.selectedPage, .compass)
        d.update(navigation: nil, rideActive: true, backtrack: state())
        XCTAssertEqual(d.selectedPage, .compass)
        d.update(navigation: nil, rideActive: true, backtrack: state(off: true, event: "off-2"))
        XCTAssertEqual(d.selectedPage, .speed)
    }
    func testMediaExpiryReevaluatesBacktrackAndOffTrackPreempts() {
        let d = driver()
        d.update(navigation: nil, rideActive: true, backtrack: state())
        d.mediaInteracted(eventIdentity: "media")
        XCTAssertEqual(d.selectedPage, .music)
        now = now.advanced(by: .seconds(5))
        d.reevaluate()
        XCTAssertEqual(d.currentDecision.primaryComponent, .backtrack)
        d.mediaInteracted(eventIdentity: "media-2")
        d.update(navigation: nil, rideActive: true, backtrack: state(off: true, event: "off-1"))
        XCTAssertEqual(d.currentDecision.reason, .backtrackOffTrack)
        XCTAssertEqual(d.selectedPage, .speed)
    }
    func testReconnectKeepsLocalRouteAndProgressRestoresFallbackNotNavigation() throws {
        var s = BacktrackSession(route: try BacktrackTestTrail.route())
        BacktrackTestTrail.feed(&s, 100, time: 0)
        BacktrackTestTrail.feed(&s, 90, time: 2)
        let saved = s
        let d = driver()
        d.update(navigation: nil, rideActive: true, backtrack: s.component(paused: false))
        d.mediaInteracted(eventIdentity: "expired-media")
        d.manuallySelect(rawValue: 2)
        now = now.advanced(by: .seconds(6))
        d.resynchronize()
        XCTAssertEqual(d.currentDecision.primaryComponent, .backtrack)
        XCTAssertEqual(d.selectedPage, .speed)
        XCTAssertEqual(s, saved)
        XCTAssertNil(d.currentDecision.temporaryExpiry)
    }
    func testPausedOrStaleOffTrackDoesNotInventUrgencyAndArrivalRemainsBacktrack() {
        let d = driver()
        d.update(navigation: nil, rideActive: true, backtrack: state())
        d.manuallySelect(rawValue: 2)
        d.update(navigation: nil, rideActive: true, backtrack: state(off: true, event: "off-1", paused: true))
        XCTAssertEqual(d.selectedPage, .compass)
        d.update(navigation: nil, rideActive: true, backtrack: state(off: true, event: "off-1", validity: .stale))
        XCTAssertEqual(d.selectedPage, .compass)
        d.update(navigation: nil, rideActive: true, backtrack: state(arrived: true))
        XCTAssertEqual(d.currentDecision.reason, .backtrackArrived)
        XCTAssertEqual(d.selectedPage, .compass)
        d.update(navigation: nil, rideActive: true)
        XCTAssertEqual(d.currentDecision.primaryComponent, .ride)
    }
}

@MainActor
private final class BacktrackWiringSource: NavigationLocationSource {
    var starts = 0, stops = 0
    var failure: (@MainActor (String) -> Void)?
    private var onFix: (@MainActor (NavigationFix) -> Void)?
    func start(onFix: @escaping @MainActor (NavigationFix) -> Void, onFailure: @escaping @MainActor (String) -> Void) throws {
        starts += 1; self.onFix = onFix; failure = onFailure
    }
    func stop() { stops += 1; onFix = nil; failure = nil }
    func emit(_ fix: NavigationFix) { onFix?(fix) }
}
private struct BacktrackWiringRoute: NavigationRouteProviding {
    func route(for request: RouteRequest) async throws -> RouteEnvelope {
        throw NavigationSourceError.unavailable("Test has no route provider data")
    }
}
