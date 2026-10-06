import XCTest
@testable import Waymate

final class PresentationCoordinatorTests: XCTestCase {
    private let start = ContinuousClock().now

    func testIdleAndRideHomes() {
        XCTAssertEqual(evaluate().primaryComponent, .idle)
        XCTAssertEqual(evaluate(ride: true).reason, .rideHome)
    }

    func testNavigationHomeOverridesRide() {
        XCTAssertEqual(evaluate(snapshot: PresentationSnapshot(), ride: true).reason, .navigationHome)
    }

    func testOffRouteAndReroutingOverrideTemporaryMedia() {
        let snapshot = PresentationSnapshot()
        snapshot.deviated = true
        XCTAssertEqual(evaluate(snapshot: snapshot).reason, .offRoute)
        XCTAssertEqual(evaluate(snapshot: snapshot, media: interaction()).reason, .offRoute)
        snapshot.phase = "rerouting"
        XCTAssertEqual(evaluate(snapshot: snapshot).reason, .rerouting)
        XCTAssertEqual(evaluate(snapshot: snapshot, media: interaction()).reason, .rerouting)
    }

    func testUserMediaTemporarilyOverridesRideAndOrdinaryNavigation() {
        for snapshot in [nil, PresentationSnapshot()] {
            let result = evaluate(snapshot: snapshot, ride: true, media: interaction())
            XCTAssertEqual(result.primaryComponent, .media)
            XCTAssertEqual(result.reason, .temporaryMedia)
            XCTAssertEqual(result.eventIdentity, "media-1")
            XCTAssertEqual(result.temporaryExpiry, start.advanced(by: .seconds(5)))
        }
    }

    func testExpiryBoundaryReevaluatesCurrentStateRatherThanPreviousPage() {
        let media = interaction()
        XCTAssertEqual(evaluate(ride: true, media: media, seconds: 4).primaryComponent, .media)
        XCTAssertEqual(evaluate(ride: true, media: media, seconds: 5).primaryComponent, .ride)
        XCTAssertEqual(evaluate(snapshot: PresentationSnapshot(), media: media, seconds: 5).primaryComponent, .navigation)
        XCTAssertEqual(evaluate(media: media, seconds: 5).primaryComponent, .idle)
    }

    func testNavigationBecomesUrgentDuringMediaWithoutRenewingExpiry() {
        let snapshot = PresentationSnapshot()
        let media = interaction()
        XCTAssertEqual(evaluate(snapshot: snapshot, media: media).primaryComponent, .media)
        snapshot.deviated = true
        XCTAssertEqual(evaluate(snapshot: snapshot, media: media, seconds: 1).primaryComponent, .navigation)
        snapshot.deviated = false
        XCTAssertEqual(evaluate(snapshot: snapshot, media: media, seconds: 2).temporaryExpiry, media.expiry)
        XCTAssertEqual(evaluate(snapshot: snapshot, media: media, seconds: 5).reason, .navigationHome)
    }

    func testRepeatedEventDoesNotRestartExpiryAndEvaluationIsDeterministic() {
        let media = interaction()
        let first = evaluate(ride: true, media: media)
        XCTAssertEqual(first, evaluate(ride: true, media: media))
        XCTAssertEqual(first, evaluate(ride: true, media: media, seconds: 4))
        for seconds in [5.0, 6, 20] {
            XCTAssertEqual(evaluate(ride: true, media: media, seconds: seconds).primaryComponent, .ride)
        }
    }

    func testNewInteractionCanStartNewTemporaryWindow() {
        XCTAssertEqual(evaluate(ride: true, media: interaction(), seconds: 6).primaryComponent, .ride)
        let next = interaction(id: "media-2", seconds: 6)
        let result = evaluate(ride: true, media: next, seconds: 6)
        XCTAssertEqual(result.eventIdentity, "media-2")
        XCTAssertEqual(result.temporaryExpiry, start.advanced(by: .seconds(11)))
        XCTAssertEqual(evaluate(ride: true, media: next, seconds: 11).primaryComponent, .ride)
    }

    func testRepeatedIdentityPreservesWindowEvenAfterExpiry() {
        let first = interaction()
        for seconds in [4.0, 6] {
            let repeated = PresentationCoordinator.MediaInteraction.begin(
                eventIdentity: first.eventIdentity,
                at: start.advanced(by: .seconds(seconds)), previous: first
            )
            XCTAssertEqual(repeated, first)
            XCTAssertEqual(evaluate(ride: true, media: repeated, seconds: seconds).primaryComponent,
                           seconds < 5 ? .media : .ride)
        }
        let next = PresentationCoordinator.MediaInteraction.begin(
            eventIdentity: "media-2", at: start.advanced(by: .seconds(6)), previous: first
        )
        XCTAssertEqual(evaluate(ride: true, media: next, seconds: 6).primaryComponent, .media)
        XCTAssertEqual(next.expiry, start.advanced(by: .seconds(11)))
    }

    func testArrivalRemainsNavigationHomeUntilAuthoritativeRouteClears() {
        let snapshot = PresentationSnapshot()
        snapshot.phase = "arrived"
        snapshot.deviated = true // Retained urgency flags do not override arrival.
        XCTAssertEqual(evaluate(snapshot: snapshot, ride: true).reason, .arrived)
        XCTAssertEqual(evaluate(snapshot: snapshot, ride: true, media: interaction()).primaryComponent, .media)
        XCTAssertEqual(evaluate(snapshot: snapshot, ride: true, media: interaction(), seconds: 5).reason, .arrived)
        snapshot.route = ""
        XCTAssertEqual(evaluate(snapshot: snapshot, ride: true).primaryComponent, .ride)
    }

    func testInvalidOrStaleLocationDoesNotInventUrgentOverride() {
        let snapshot = PresentationSnapshot()
        for phase in ["navigating", "rerouting"] {
            snapshot.phase = phase
            snapshot.deviated = true
            for (usable, stale) in [(false, false), (true, true), (false, true)] {
                snapshot.usable = usable
                snapshot.stale = stale
                XCTAssertEqual(evaluate(snapshot: snapshot, media: interaction()).primaryComponent, .media)
                XCTAssertEqual(evaluate(snapshot: snapshot).reason, .navigationHome)
            }
        }
    }

    func testMissingRouteAndInactivePhasesCannotPreemptMediaOrRide() {
        let snapshot = PresentationSnapshot()
        snapshot.deviated = true
        snapshot.route = ""
        XCTAssertEqual(evaluate(snapshot: snapshot, ride: true).primaryComponent, .ride)
        XCTAssertEqual(evaluate(snapshot: snapshot, media: interaction()).primaryComponent, .media)
        snapshot.route = "route-1"
        for phase in ["idle", "acquiring", "planning"] {
            snapshot.phase = phase
            XCTAssertEqual(evaluate(snapshot: snapshot).primaryComponent, .idle)
        }
    }

    func testManeuverDistanceAloneDoesNotInventUrgency() {
        XCTAssertEqual(evaluate(snapshot: PresentationSnapshot(), media: interaction()).primaryComponent, .media)
    }

    func testFutureInteractionDoesNotShowEarly() {
        XCTAssertEqual(evaluate(ride: true, media: interaction(seconds: 1)).primaryComponent, .ride)
    }

    private func interaction(id: String = "media-1", seconds: Double = 0) -> PresentationCoordinator.MediaInteraction {
        .begin(eventIdentity: id, at: start.advanced(by: .seconds(seconds)))
    }

    private func evaluate(
        snapshot: PresentationSnapshot? = nil,
        ride: Bool = false,
        media: PresentationCoordinator.MediaInteraction? = nil,
        seconds: Double = 0
    ) -> PresentationDecision {
        PresentationCoordinator.evaluate(
            input: .init(
                navigation: snapshot.map { NavigationComponentState(snapshot: $0) },
                rideActive: ride, mediaInteraction: media
            ),
            now: start.advanced(by: .seconds(seconds))
        )
    }
}

/// Only snapshot getters are used; no runtime, navigation or display calls.
private final class PresentationSnapshot: MotoNavCoreSnapshot {
    var phase = "navigating"
    var route = "route-1"
    var deviated = false
    var usable = true
    var stale = false

    override var stateName: String { phase }
    override var routeID: String { route }
    override var routeGeneration: UInt32 { 1 }
    override var hasNextManeuver: Bool { true }
    override var maneuverID: UInt32 { 42 }
    override var distanceToManeuverM: Double { 0 }
    override var offRoute: Bool { deviated }
    override var hasUsableFix: Bool { usable }
    override var gnssStale: Bool { stale }
}
