import MotoNavigationCore
import XCTest
@testable import Waymate

@MainActor
final class PresentationProductionWiringTests: XCTestCase {
    private var now = ContinuousClock().now
    private var pages: [RoundDisplayPage] = []

    private func driver() -> PresentationDriver {
        let driver = PresentationDriver(now: { self.now }, schedulesExpiry: false)
        driver.onSelection = { self.pages.append($0) }
        return driver
    }

    private func state(_ snapshot: WiringNavigationSnapshot = WiringNavigationSnapshot()) -> NavigationComponentState {
        NavigationComponentState(snapshot: snapshot)
    }

    func testExistingProtocolMappingAndIdleStartup() {
        XCTAssertEqual(RoundDisplayPage(primary: .idle), .navigation)
        XCTAssertEqual(RoundDisplayPage(primary: .ride), .speed)
        XCTAssertEqual(RoundDisplayPage(primary: .navigation), .navigation)
        XCTAssertEqual(RoundDisplayPage(primary: .media), .music)
        XCTAssertEqual(RoundDisplayPage.allCases.map(\.rawValue), [0, 1, 2, 3])
        let driver = driver()
        for _ in 0..<100 { driver.update(navigation: nil, rideActive: false) }
        XCTAssertEqual(pages, [.navigation])
        XCTAssertEqual(driver.decision?.reason, .idle)
    }

    func testRideLocationRefreshDoesNotReselectPage() {
        let driver = driver()
        driver.update(navigation: nil, rideActive: false)
        driver.update(navigation: nil, rideActive: true)
        for _ in 0..<100 { driver.update(navigation: nil, rideActive: true) }
        XCTAssertEqual(pages, [.navigation, .speed])
        driver.update(navigation: nil, rideActive: false)
        XCTAssertEqual(pages.last, .navigation)
        XCTAssertEqual(driver.decision?.reason, .idle)
    }

    func testNavigationStartEndAndOrdinarySnapshots() {
        let driver = driver()
        driver.update(navigation: nil, rideActive: true)
        let snapshot = WiringNavigationSnapshot()
        driver.update(navigation: state(snapshot), rideActive: true)
        for distance in 0..<100 {
            snapshot.distance = Double(distance)
            driver.update(navigation: state(snapshot), rideActive: true)
        }
        XCTAssertEqual(pages, [.speed, .navigation])
        driver.update(navigation: nil, rideActive: true)
        XCTAssertEqual(pages, [.speed, .navigation, .speed])
    }

    func testManualCompassSurvivesTicksAndUrgentNavigationReclaimsOnce() {
        let driver = driver()
        let snapshot = WiringNavigationSnapshot()
        driver.update(navigation: state(snapshot), rideActive: true)
        XCTAssertTrue(driver.manuallySelect(rawValue: 2))
        for _ in 0..<100 { driver.update(navigation: state(snapshot), rideActive: true) }
        XCTAssertEqual(pages, [.navigation, .compass])
        snapshot.deviated = true
        driver.update(navigation: state(snapshot), rideActive: true)
        for _ in 0..<100 { driver.update(navigation: state(snapshot), rideActive: true) }
        XCTAssertEqual(pages, [.navigation, .compass, .navigation])
        // Remaining urgent is a fact refresh, not a new presentation event.
        driver.manuallySelect(rawValue: 2)
        driver.update(navigation: state(snapshot), rideActive: true)
        XCTAssertEqual(driver.selectedPage, .compass)
        snapshot.phase = "rerouting"
        driver.update(navigation: state(snapshot), rideActive: true)
        XCTAssertEqual(driver.selectedPage, .navigation)
        XCTAssertEqual(driver.decision?.reason, .rerouting)
    }

    func testEndRideCannotSwitchAwayFromNavigationOrManualCompass() {
        let driver = driver()
        let navigation = state()
        driver.update(navigation: navigation, rideActive: true)
        driver.update(navigation: navigation, rideActive: false)
        XCTAssertEqual(pages, [.navigation])
        driver.manuallySelect(rawValue: 2)
        driver.update(navigation: navigation, rideActive: true)
        driver.update(navigation: navigation, rideActive: false)
        XCTAssertEqual(driver.selectedPage, .compass)
        XCTAssertEqual(driver.decision?.primaryComponent, .navigation)
    }

    func testAutomaticMediaExpiryReevaluatesCurrentFactsForAllHomes() {
        for home in PresentationDecision.primaryComponentHomes {
            pages = []
            let driver = driver()
            driver.update(navigation: nil, rideActive: true)
            driver.mediaInteracted(eventIdentity: "event")
            XCTAssertEqual(driver.selectedPage, .music)
            now = now.advanced(by: .seconds(4))
            driver.update(navigation: home == .navigation ? state() : nil, rideActive: home == .ride)
            XCTAssertEqual(driver.selectedPage, .music)
            now = now.advanced(by: .seconds(1))
            driver.reevaluate()
            XCTAssertEqual(driver.decision?.primaryComponent, home)
            XCTAssertEqual(driver.selectedPage, RoundDisplayPage(primary: home))
            XCTAssertEqual(pages.count, 3)
        }
    }

    func testOrdinaryNavigationAllowsMediaAndUrgencyInterruptsIt() {
        let driver = driver()
        let snapshot = WiringNavigationSnapshot()
        driver.update(navigation: state(snapshot), rideActive: true)
        driver.mediaInteracted(eventIdentity: "media")
        XCTAssertEqual(driver.selectedPage, .music)
        let expiry = driver.decision?.temporaryExpiry
        snapshot.deviated = true
        driver.update(navigation: state(snapshot), rideActive: true)
        XCTAssertEqual(driver.selectedPage, .navigation)
        XCTAssertEqual(driver.decision?.reason, .offRoute)
        driver.mediaInteracted(eventIdentity: "media")
        XCTAssertEqual(pages, [.navigation, .music, .navigation])
        snapshot.deviated = false
        driver.update(navigation: state(snapshot), rideActive: true)
        XCTAssertEqual(driver.decision?.temporaryExpiry, expiry)
        now = now.advanced(by: .seconds(5))
        driver.reevaluate()
        XCTAssertEqual(driver.selectedPage, .navigation)
    }

    func testSameMediaIdentityCannotRenewAndNewIdentityPresentsAgain() {
        let driver = driver()
        driver.update(navigation: nil, rideActive: true)
        driver.mediaInteracted(eventIdentity: "one")
        let first = driver.mediaInteraction
        now = now.advanced(by: .seconds(4))
        for _ in 0..<100 { driver.mediaInteracted(eventIdentity: "one"); driver.reevaluate() }
        XCTAssertEqual(driver.mediaInteraction, first)
        XCTAssertEqual(pages, [.speed, .music])
        driver.mediaInteracted(eventIdentity: "two")
        XCTAssertEqual(pages, [.speed, .music, .music])
        XCTAssertEqual(driver.decision?.temporaryExpiry, now.advanced(by: .seconds(5)))
        now = now.advanced(by: .seconds(5))
        driver.reevaluate()
        driver.mediaInteracted(eventIdentity: "two")
        XCTAssertEqual(driver.selectedPage, .speed)
        XCTAssertEqual(pages, [.speed, .music, .music, .speed])
    }

    func testManualMusicAndControlsStayPastExpiry() {
        let driver = driver()
        driver.update(navigation: nil, rideActive: true)
        driver.manuallySelect(rawValue: 3)
        driver.mediaInteracted(eventIdentity: "manual-control")
        now = now.advanced(by: .seconds(30))
        driver.reevaluate()
        XCTAssertEqual(pages, [.speed, .music])
        XCTAssertEqual(driver.selectedPage, .music)
        XCTAssertNil(driver.decision?.temporaryExpiry)
    }

    func testManualBrowseDismissesAutomaticWindowWithoutRevivingSameEvent() {
        for page in [RoundDisplayPage.music, .compass] {
            pages = []
            let driver = driver()
            driver.update(navigation: state(), rideActive: true)
            driver.mediaInteracted(eventIdentity: "auto")
            driver.manuallySelect(rawValue: page.rawValue)
            now = now.advanced(by: .seconds(6))
            driver.reevaluate()
            driver.mediaInteracted(eventIdentity: "auto")
            XCTAssertEqual(driver.selectedPage, page)
            XCTAssertEqual(pages.count, 3)
            // Controls from a non-Music browse open a new automatic window.
            if page == .compass {
                driver.mediaInteracted(eventIdentity: "new")
                XCTAssertEqual(driver.selectedPage, .music)
            }
        }
    }

    func testResyncRestoresCurrentHomeEvenAfterManualBrowse() {
        for home in PresentationDecision.primaryComponentHomes {
            let driver = driver()
            driver.update(navigation: home == .navigation ? state() : nil, rideActive: home == .ride)
            driver.manuallySelect(rawValue: 2)
            let count = pages.count
            driver.resynchronize()
            XCTAssertEqual(pages.count, count + 1)
            XCTAssertEqual(driver.selectedPage, RoundDisplayPage(primary: home))
        }
    }

    func testResyncDoesNotReviveExpiredMediaOrReplayCommands() {
        let driver = driver()
        driver.update(navigation: state(), rideActive: true)
        driver.mediaInteracted(eventIdentity: "event")
        now = now.advanced(by: .seconds(4))
        driver.resynchronize()
        XCTAssertEqual(driver.selectedPage, .music)
        now = now.advanced(by: .seconds(1))
        driver.resynchronize()
        XCTAssertEqual(driver.selectedPage, .navigation)
        driver.mediaInteracted(eventIdentity: "event")
        XCTAssertEqual(driver.selectedPage, .navigation)
        XCTAssertEqual(pages, [.navigation, .music, .music, .navigation])
    }

    func testArrivalKeepsNavigationHomeWithoutInventingUrgency() {
        let driver = driver()
        let snapshot = WiringNavigationSnapshot()
        driver.update(navigation: state(snapshot), rideActive: true)
        snapshot.phase = "arrived"
        snapshot.deviated = true
        driver.update(navigation: state(snapshot), rideActive: true)
        XCTAssertEqual(driver.decision?.reason, .arrived)
        XCTAssertEqual(pages, [.navigation])
        driver.manuallySelect(rawValue: 2)
        driver.update(navigation: state(snapshot), rideActive: true)
        XCTAssertEqual(driver.selectedPage, .compass)
    }

    func testStaleFixDoesNotInventUrgentPresentationAndInvalidPageIsRejected() {
        let driver = driver()
        let snapshot = WiringNavigationSnapshot()
        driver.update(navigation: state(snapshot), rideActive: false)
        driver.manuallySelect(rawValue: 2)
        snapshot.deviated = true
        snapshot.stale = true
        driver.update(navigation: state(snapshot), rideActive: false)
        XCTAssertEqual(driver.selectedPage, .compass)
        XCTAssertFalse(driver.manuallySelect(rawValue: 4))
        XCTAssertEqual(driver.selectedPage, .compass)
        snapshot.stale = false
        driver.update(navigation: state(snapshot), rideActive: false)
        XCTAssertEqual(driver.selectedPage, .navigation)
    }

    func testAppModelRideAndPausedHomeWithBLEUnavailable() async {
        let source = PresentationLocationSource()
        let driver = driver()
        let model = AppModel(startsServices: false, locationSource: source, presentationDriver: driver)
        XCTAssertEqual(driver.selectedPage, .navigation)
        model.startRide()
        XCTAssertEqual(driver.selectedPage, .speed)
        driver.manuallySelect(rawValue: 2)
        source.emit()
        XCTAssertEqual(driver.selectedPage, .compass)
        model.pauseRide()
        XCTAssertEqual(model.rideSessionState, .paused)
        XCTAssertEqual(driver.selectedPage, .compass)
        driver.resynchronize()
        XCTAssertEqual(driver.selectedPage, .speed)
        XCTAssertEqual(model.rideSessionState, .paused)
        model.stopRide()
        XCTAssertEqual(driver.selectedPage, .navigation)
        XCTAssertEqual(model.device.connection, .idle)
        XCTAssertFalse(model.isNavigationActive)
    }

    func testAppModelAcceptedRouteEndNavigationAndEndRideAreIndependent() async {
        let source = PresentationLocationSource()
        let driver = driver()
        let model = AppModel(startsServices: false, locationSource: source, presentationDriver: driver)
        model.beginLiveNavigation(destination: .init(longitudeDeg: 117.13, latitudeDeg: 36.66),
                                  routeProvider: PresentationRouteProvider())
        XCTAssertEqual(driver.selectedPage, .speed)
        source.emit()
        for _ in 0..<200 {
            if model.navigationComponentState.isNavigationValid { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.navigationComponentState.isNavigationValid)
        XCTAssertEqual(driver.selectedPage, .navigation)
        model.stopRide()
        XCTAssertTrue(model.isNavigationActive)
        XCTAssertEqual(driver.selectedPage, .navigation)
        model.startRide()
        model.stopNavigation()
        XCTAssertTrue(model.rideActive)
        XCTAssertEqual(driver.selectedPage, .speed)
        model.stopRide()
        XCTAssertEqual(driver.selectedPage, .navigation)
    }

    func testTransportCacheRetainsDriverPageWithSnapshotAndAcrossResync() {
        var cache = BLENavigationStateCache()
        let snapshot = MotoNavCoreBridge().snapshot
        cache.update(snapshot, displayPageName: "speed")
        XCTAssertTrue(cache.takePending() === snapshot)
        cache.resynchronize()
        XCTAssertEqual(cache.displayPageName, "speed")
        XCTAssertTrue(cache.takePending() === snapshot)
        cache.update(snapshot, displayPageName: "compass")
        XCTAssertEqual(cache.displayPageName, "compass")
        XCTAssertEqual(snapshot.displayPageName, "navigation", "NavCore is not a competing presentation owner")
    }

    func testProductionBLEInputConsumesDriverPageWithoutChangingNavigationFacts() throws {
        let central = ESP32BLECentral() // Does not connect or start CoreBluetooth.
        let snapshot = MotoNavCoreBridge().snapshot
        let codec = MotoBLEProtocolCodec(maximumFrameSize: 182)
        for page in RoundDisplayPage.allCases {
            central.sendNavigationSnapshot(snapshot, displayPage: page)
            let input = central.makeSnapshotInput(snapshot, codec: codec)
            XCTAssertEqual(input.displayPageName, page.protocolName)
            XCTAssertEqual(input.stateName, snapshot.stateName)
            XCTAssertEqual(input.routeGeneration, snapshot.routeGeneration)
            XCTAssertFalse(input.hasDestination)
            XCTAssertFalse(try codec.encodeNavigationSnapshot(input).isEmpty)
            XCTAssertEqual(snapshot.displayPageName, "navigation")
        }
    }

    func testProductionExpiryTaskReevaluatesLatestFactsWithoutNavigationTicks() async {
        // Use an already elapsed real deadline and controlled logical time;
        // exercise the production task without a five-second test sleep.
        now = ContinuousClock().now.advanced(by: .seconds(-6))
        let driver = PresentationDriver(now: { self.now })
        driver.update(navigation: nil, rideActive: true)
        driver.mediaInteracted(eventIdentity: "scheduled")
        XCTAssertEqual(driver.selectedPage, .music)
        driver.update(navigation: state(), rideActive: true)
        now = now.advanced(by: .seconds(5))
        for _ in 0..<200 {
            if driver.selectedPage == .navigation { break }
            await Task.yield()
        }
        XCTAssertEqual(driver.selectedPage, .navigation)
        XCTAssertEqual(driver.decision?.reason, .navigationHome)
    }

    func testManualMusicCancelsAlreadyScheduledExpiry() async {
        now = ContinuousClock().now.advanced(by: .seconds(-6))
        let driver = PresentationDriver(now: { self.now })
        driver.update(navigation: nil, rideActive: true)
        driver.mediaInteracted(eventIdentity: "scheduled")
        driver.manuallySelect(rawValue: 3)
        now = now.advanced(by: .seconds(6))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(driver.selectedPage, .music)
        XCTAssertEqual(driver.decision?.reason, .rideHome)
    }
}

private extension PresentationDecision {
    static let primaryComponentHomes: [PrimaryComponent] = [.idle, .ride, .navigation]
}

private final class WiringNavigationSnapshot: MotoNavCoreSnapshot {
    var phase = "navigating"
    var deviated = false
    var stale = false
    var distance = 100.0
    override var stateName: String { phase }
    override var routeID: String { "route" }
    override var routeGeneration: UInt32 { 1 }
    override var offRoute: Bool { deviated }
    override var gnssStale: Bool { stale }
    override var hasUsableFix: Bool { true }
    override var hasNextManeuver: Bool { true }
    override var distanceToManeuverM: Double { distance }
}

@MainActor
private final class PresentationLocationSource: NavigationLocationSource {
    private var onFix: (@MainActor (NavigationFix) -> Void)?
    func start(onFix: @escaping @MainActor (NavigationFix) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) throws { self.onFix = onFix }
    func stop() { onFix = nil }
    func emit() {
        onFix?(.init(coordinate: .init(longitudeDeg: 117.12, latitudeDeg: 36.67),
                     horizontalAccuracyM: 3, speedMps: nil, timestamp: Date()))
    }
}

private struct PresentationRouteProvider: NavigationRouteProviding {
    func route(for request: RouteRequest) async throws -> RouteEnvelope {
        RouteEnvelope(requestID: request.requestID, route: RoutePlan(
            routeID: "presentation-wiring", provider: "test", generatedAtMs: 1,
            totalDistanceM: 1500, totalDurationS: 360,
            polyline: [.init(longitudeDeg: 117.12, latitudeDeg: 36.67),
                       .init(longitudeDeg: 117.13, latitudeDeg: 36.66)], maneuvers: [], traffic: []))
    }
}
