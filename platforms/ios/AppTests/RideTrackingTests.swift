import CoreLocation
import Foundation
import MotoNavigationCore
import XCTest
@testable import Waymate

final class RideTrackingTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000)
    private func time(_ seconds: Double) -> Date { origin.addingTimeInterval(seconds) }
    private func fix(_ seconds: Double, meters: Double = 0, speed: Double? = 5,
                     accuracy: Double = 3, latitude: Double? = nil) -> NavigationFix {
        NavigationFix(coordinate: .init(longitudeDeg: 117,
                                        latitudeDeg: latitude ?? (36 + meters / 111_000)),
                      horizontalAccuracyM: accuracy, speedMps: speed, timestamp: time(seconds))
    }
    private func feed(_ session: inout RideSession, _ seconds: Double,
                      meters: Double = 0, speed: Double? = 5) {
        session.accept(fix(seconds, meters: meters, speed: speed), receivedAt: time(seconds))
    }

    func testStartAndFirstPoint() {
        var ride = RideSession()
        ride.start(at: origin)
        XCTAssertEqual(ride.startedAt, origin)
        XCTAssertEqual(ride.state, .active)
        feed(&ride, 1)
        XCTAssertEqual(ride.track.count, 1)
        XCTAssertEqual(ride.track[0].timestamp, time(1))
        XCTAssertEqual(ride.track[0].horizontalAccuracy, 3)
        XCTAssertEqual(ride.track[0].segment, 0)
        XCTAssertEqual(ride.distance, 0)
        XCTAssertEqual(ride.movingTime, 0)
    }

    func testTrackDistanceMovingTimeSpeedAndRecord() throws {
        var ride = RideSession()
        ride.start(at: origin)
        feed(&ride, 0)
        feed(&ride, 2, meters: 10, speed: 6)
        feed(&ride, 4, meters: 20, speed: 4)
        XCTAssertEqual(ride.track.count, 3)
        let expected = CLLocation(latitude: 36, longitude: 117).distance(
            from: CLLocation(latitude: 36 + 20 / 111_000.0, longitude: 117))
        XCTAssertEqual(ride.distance, expected, accuracy: 0.01)
        XCTAssertEqual(ride.movingTime, 4)
        XCTAssertEqual(ride.currentSpeed(at: time(4)), 4)
        XCTAssertEqual(ride.maxSpeed, 6)
        let record = try XCTUnwrap(ride.stop(at: time(10)))
        XCTAssertEqual(ride.state, .inactive)
        XCTAssertEqual(record.startedAt, origin)
        XCTAssertEqual(record.endedAt, time(10))
        XCTAssertEqual(record.elapsedTime, 10)
        XCTAssertEqual(record.movingTime, 4)
        XCTAssertEqual(record.distance, expected, accuracy: 0.01)
        XCTAssertEqual(record.averageSpeed!, expected / 4, accuracy: 0.001)
        XCTAssertEqual(record.maxSpeed, 6)
        XCTAssertEqual(record.track, ride.track)
        XCTAssertNil(ride.currentSpeed(at: time(10)))
        feed(&ride, 11, meters: 30)
        XCTAssertEqual(ride.record, record)
        XCTAssertEqual(ride.stop(at: time(20)), record)
    }

    func testInvalidLocationsDoNotPolluteAnyMetric() {
        var ride = RideSession()
        ride.start(at: origin)
        feed(&ride, 0)
        let before = ride
        for bad in [fix(2, latitude: 91), fix(2, latitude: .nan),
                    fix(2, accuracy: -1), fix(2, accuracy: .infinity), fix(2, accuracy: 51),
                    fix(-1), fix(40), fix(0)] {
            ride.accept(bad, receivedAt: time(2))
            XCTAssertEqual(ride, before)
        }
        ride.accept(fix(1), receivedAt: time(17)) // stale
        XCTAssertEqual(ride, before)
    }

    func testUnknownAndInvalidSpeedsAreNotStatistics() {
        for speed in [nil, -1, Double.nan, Double.infinity, 101] as [Double?] {
            var ride = RideSession()
            ride.start(at: origin)
            feed(&ride, 0, speed: speed)
            feed(&ride, 2, meters: 10, speed: speed)
            XCTAssertNil(ride.currentSpeed(at: time(2)))
            XCTAssertNil(ride.track.last?.speed)
            XCTAssertNil(ride.maxSpeed)
            XCTAssertEqual(ride.movingTime, 0)
            XCTAssertGreaterThan(ride.distance, 9) // actual displacement, not speed integration
            XCTAssertNil(ride.stop(at: time(4))?.averageSpeed) // zero moving time despite distance
        }
    }

    func testStationaryJitterDoesNotAccumulate() {
        var ride = RideSession()
        ride.start(at: origin)
        for second in 0...120 {
            feed(&ride, Double(second), meters: Double(second % 3), speed: 0.2)
        }
        XCTAssertEqual(ride.track.count, 1)
        XCTAssertEqual(ride.distance, 0)
        XCTAssertEqual(ride.movingTime, 0)
        XCTAssertEqual(ride.maxSpeed, 0)
        XCTAssertEqual(ride.elapsedTime(at: time(120)), 120)
    }

    func testMovingThresholdAndTransitions() {
        var ride = RideSession()
        ride.start(at: origin)
        feed(&ride, 0, speed: 0)
        feed(&ride, 1, meters: 1, speed: 0.5)
        feed(&ride, 2, meters: 2, speed: 0.5)
        feed(&ride, 3, meters: 2, speed: 0)
        feed(&ride, 4, meters: 3, speed: 1)
        feed(&ride, 5, meters: 4, speed: 1)
        XCTAssertEqual(ride.movingTime, 2) // only the two confirmed moving intervals
    }

    func testObviousJumpIsRejectedAndRecoveryUsesLastGoodFix() {
        var ride = RideSession()
        ride.start(at: origin)
        feed(&ride, 0)
        let before = ride
        feed(&ride, 1, meters: 1_000, speed: 80)
        XCTAssertEqual(ride, before)
        feed(&ride, 2, meters: 10)
        XCTAssertEqual(ride.track.count, 2)
        XCTAssertEqual(ride.maxSpeed, 5)
        XCTAssertEqual(ride.movingTime, 2)
        XCTAssertLessThan(ride.distance, 11)
    }

    func testGPSGapCreatesSegmentAndDoesNotInventTravelOrTime() {
        var ride = RideSession()
        ride.start(at: origin)
        feed(&ride, 0)
        feed(&ride, 2, meters: 10)
        let distance = ride.distance
        feed(&ride, 30, meters: 1_000)
        XCTAssertEqual(ride.track.last?.segment, 1)
        XCTAssertEqual(ride.distance, distance)
        XCTAssertEqual(ride.movingTime, 2)
        feed(&ride, 32, meters: 1_010)
        XCTAssertEqual(ride.movingTime, 4)
        XCTAssertLessThan(ride.distance, 21)
    }

    func testPauseResumeAndNoCrossPauseDistance() throws {
        var ride = RideSession()
        ride.start(at: origin)
        feed(&ride, 0)
        feed(&ride, 2, meters: 10)
        ride.pause(at: time(3))
        XCTAssertEqual(ride.state, .paused)
        XCTAssertTrue(ride.isActive)
        let paused = ride
        feed(&ride, 20, meters: 1_000)
        ride.pause(at: time(20))
        ride.start(at: time(20))
        XCTAssertEqual(ride, paused)
        XCTAssertEqual(ride.elapsedTime(at: time(20)), 3)
        ride.resume(at: time(30))
        let resumed = ride
        ride.resume(at: time(31))
        XCTAssertEqual(ride, resumed)
        ride.accept(fix(29, meters: 1_000), receivedAt: time(30))
        XCTAssertEqual(ride, resumed) // queued pre-resume fix
        feed(&ride, 30, meters: 1_000)
        XCTAssertEqual(ride.distance, paused.distance)
        XCTAssertEqual(ride.track.last?.segment, 1)
        feed(&ride, 32, meters: 1_010)
        let record = try XCTUnwrap(ride.stop(at: time(35)))
        XCTAssertEqual(record.elapsedTime, 8)
        XCTAssertEqual(record.movingTime, 4)
        XCTAssertLessThan(record.distance, 21)
        XCTAssertEqual(record.endedAt.timeIntervalSince(record.startedAt), 35)
    }

    func testStopWhilePausedAndEmptyRide() throws {
        var ride = RideSession()
        XCTAssertNil(ride.stop(at: origin))
        ride.pause(at: origin)
        ride.resume(at: origin)
        XCTAssertEqual(ride.state, .inactive)
        ride.start(at: origin)
        ride.pause(at: time(5))
        let record = try XCTUnwrap(ride.stop(at: time(20)))
        XCTAssertEqual(record.elapsedTime, 5)
        XCTAssertEqual(record.distance, 0)
        XCTAssertEqual(record.track, [])
        XCTAssertNil(record.averageSpeed)
        ride.start(at: time(30))
        XCTAssertNil(ride.record)
        XCTAssertEqual(ride.startedAt, time(30))
    }

    func testRepeatedStartPreservesMetrics() {
        var ride = RideSession()
        ride.start(at: origin)
        feed(&ride, 0)
        feed(&ride, 2, meters: 10)
        let before = ride
        ride.start(at: time(100))
        XCTAssertEqual(ride, before)
    }

    func testCurrentSpeedExpiresWithoutTick() {
        var ride = RideSession()
        ride.start(at: origin)
        feed(&ride, 0)
        XCTAssertEqual(ride.currentSpeed(at: time(15)), 5)
        XCTAssertNil(ride.currentSpeed(at: time(16)))
    }

    func testSubsecondInputAndLongRideSamplingBound() {
        var ride = RideSession()
        ride.start(at: origin)
        // Four hours at 10 Hz; the owner clock advances with observations.
        for index in 0...144_000 {
            let seconds = Double(index) / 10
            feed(&ride, seconds, meters: seconds * 5)
        }
        XCTAssertEqual(ride.track.count, 7_201)
        XCTAssertEqual(ride.movingTime, 14_400, accuracy: 0.001)
        XCTAssertGreaterThan(ride.distance, 71_000)
        XCTAssertLessThan(ride.distance, 73_000)
        XCTAssertTrue(zip(ride.track, ride.track.dropFirst()).allSatisfy {
            $1.timestamp.timeIntervalSince($0.timestamp) >= 2
        })
    }

    func testStopFlushesUnsampledMovingEndpoint() {
        var ride = RideSession()
        ride.start(at: origin)
        feed(&ride, 0)
        feed(&ride, 1, meters: 5)
        XCTAssertEqual(ride.track.count, 1)
        ride.stop(at: time(1))
        XCTAssertEqual(ride.track.count, 2)
        XCTAssertGreaterThan(ride.distance, 4)
    }

    @MainActor
    func testRideOnlyLocationOwnershipAndPauseResume() async {
        let source = TrackingTestSource()
        var now = origin
        let model = AppModel(startsServices: false, locationSource: source, rideNow: { now })
        model.startRide()
        model.startRide()
        XCTAssertEqual(source.starts, 1)
        XCTAssertFalse(model.isNavigationActive)
        source.emit(fix(0))
        now = time(2)
        source.emit(fix(2, meters: 10))
        XCTAssertEqual(model.rideTrack.count, 2)
        XCTAssertGreaterThan(model.rideDistance, 9)
        model.pauseRide()
        XCTAssertEqual(source.stops, 1)
        now = time(20)
        source.emit(fix(20, meters: 1_000))
        XCTAssertEqual(model.rideTrack.count, 2)
        model.resumeRide()
        model.resumeRide()
        XCTAssertEqual(source.starts, 2)
        source.emit(fix(20, meters: 1_000))
        XCTAssertLessThan(model.rideDistance, 11)
        model.stopRide()
        model.stopRide()
        XCTAssertEqual(source.stops, 2)
        XCTAssertNotNil(model.rideRecord)
        XCTAssertEqual(model.rideRecord?.elapsedTime, 2)
    }

    @MainActor
    func testNavigationAndRideShareOneStreamInEitherStartOrder() async throws {
        for rideFirst in [true, false] {
            let source = TrackingTestSource()
            let shared = SharedLocationSource(source: source)
            var ride = RideSession()
            ride.start(at: origin)
            var navigationFixes: [NavigationFix] = []
            var now = origin
            func startRide() throws {
                try shared.startRide(onFix: { ride.accept($0, receivedAt: now) }, onFailure: { _ in })
            }
            func startNavigation() throws {
                try shared.start(onFix: { navigationFixes.append($0) }, onFailure: { _ in })
            }
            if rideFirst { try startRide(); try startNavigation() }
            else { try startNavigation(); try startRide() }
            XCTAssertEqual(source.starts, 1)
            source.emit(fix(0))
            now = time(2)
            source.emit(fix(2, meters: 10))
            XCTAssertEqual(navigationFixes.count, 2)
            XCTAssertEqual(ride.track.count, 2)
            shared.stop()
            XCTAssertEqual(source.stops, 0)
            now = time(4)
            source.emit(fix(4, meters: 20))
            XCTAssertEqual(navigationFixes.count, 2)
            XCTAssertEqual(ride.track.count, 3)
            shared.stopRide()
            XCTAssertEqual(source.stops, 1)
        }
    }

    @MainActor
    func testRideStopDoesNotStopNavigationAndRestartDoesNotDuplicateStream() async throws {
        let source = TrackingTestSource()
        let shared = SharedLocationSource(source: source)
        var navigationCount = 0
        var rideCount = 0
        try shared.start(onFix: { _ in navigationCount += 1 }, onFailure: { _ in })
        try shared.startRide(onFix: { _ in rideCount += 1 }, onFailure: { _ in })
        shared.stopRide()
        XCTAssertEqual(source.stops, 0)
        source.emit(fix(0))
        XCTAssertEqual(navigationCount, 1)
        XCTAssertEqual(rideCount, 0)
        shared.stop()
        try shared.start(onFix: { _ in navigationCount += 1 }, onFailure: { _ in })
        XCTAssertEqual(source.starts, 2)
        source.emit(fix(1))
        XCTAssertEqual(navigationCount, 2)
        shared.stop()
        shared.stop()
        XCTAssertEqual(source.stops, 2)
    }

    func testRapidStopMotionOscillationRespectsSamplingBound() {
        var ride = RideSession()
        ride.start(at: origin)
        for index in 0...1_000 {
            let seconds = Double(index) / 10
            feed(&ride, seconds, meters: seconds, speed: index.isMultiple(of: 2) ? 0 : 1)
        }
        XCTAssertLessThanOrEqual(ride.track.count, 51)
        XCTAssertEqual(ride.distance, 0) // each movement resumes with a fresh anchor
    }

    @MainActor
    func testNavigationRideInterfaceStartsRideAndEndDoesNotStopIt() async {
        let source = TrackingTestSource()
        var now = origin
        let model = AppModel(startsServices: false, locationSource: source, rideNow: { now })
        model.beginLiveNavigation(destination: .init(longitudeDeg: 117.1, latitudeDeg: 36.1),
                                  routeProvider: TrackingTestRouteProvider())
        XCTAssertTrue(model.isNavigationActive)
        XCTAssertTrue(model.rideActive)
        XCTAssertEqual(source.starts, 1)
        source.emit(fix(0))
        now = time(2)
        source.emit(fix(2, meters: 10))
        XCTAssertEqual(model.rideTrack.count, 2)
        model.beginLiveNavigation(destination: .init(longitudeDeg: 117.2, latitudeDeg: 36.2),
                                  routeProvider: TrackingTestRouteProvider())
        XCTAssertEqual(source.starts, 1)
        XCTAssertEqual(model.rideTrack.count, 2) // rerouting/start does not replace Ride
        model.stopNavigation()
        XCTAssertTrue(model.rideActive)
        XCTAssertEqual(source.stops, 0)
        now = time(4)
        source.emit(fix(4, meters: 20))
        XCTAssertEqual(model.rideTrack.count, 3)
        model.stopRide()
        XCTAssertEqual(source.stops, 1)
        XCTAssertEqual(model.rideRecord?.startedAt, origin)
    }

    @MainActor
    func testFailedFormalNavigationDoesNotCreateRide() async {
        let source = TrackingTestSource()
        source.failStart = true
        let model = AppModel(startsServices: false, locationSource: source, rideNow: { self.origin })
        model.beginLiveNavigation(destination: .init(longitudeDeg: 117.1, latitudeDeg: 36.1),
                                  routeProvider: TrackingTestRouteProvider())
        XCTAssertFalse(model.isNavigationActive)
        XCTAssertFalse(model.rideActive)
        XCTAssertNil(model.rideRecord)
    }

    @MainActor
    func testPauseAndStopRideLeaveNavigationLocationRunning() async {
        let source = TrackingTestSource()
        var now = origin
        let model = AppModel(startsServices: false, locationSource: source, rideNow: { now })
        model.beginLiveNavigation(destination: .init(longitudeDeg: 117.1, latitudeDeg: 36.1),
                                  routeProvider: TrackingTestRouteProvider())
        source.emit(fix(0))
        now = time(2)
        source.emit(fix(2, meters: 10))
        model.pauseRide()
        XCTAssertEqual(source.stops, 0)
        now = time(20)
        source.emit(fix(20, meters: 1_000))
        XCTAssertEqual(model.rideTrack.count, 2)
        XCTAssertEqual(model.rideMovingTime, 2)
        // End Nav, then choose another destination while keeping the paused Ride.
        model.stopNavigation()
        model.beginLiveNavigation(destination: .init(longitudeDeg: 117.2, latitudeDeg: 36.2),
                                  routeProvider: TrackingTestRouteProvider())
        XCTAssertEqual(model.rideSessionState, .paused)
        model.resumeRide()
        XCTAssertEqual(source.starts, 2)
        source.emit(fix(20, meters: 1_000))
        XCTAssertLessThan(model.rideDistance, 11)
        model.stopRide()
        XCTAssertEqual(source.stops, 1)
        XCTAssertTrue(model.isNavigationActive)
        model.stopNavigation()
        XCTAssertEqual(source.stops, 2)
    }

    @MainActor
    func testProductionAutomaticRideLinkStartsWithoutExtraCommand() async {
        let source = TrackingTestSource()
        let model = AppModel(startsServices: false, locationSource: source, rideNow: { self.origin })
        XCTAssertFalse(model.rideActive)
        model.beginLiveNavigation(destination: .init(longitudeDeg: 117.1, latitudeDeg: 36.1),
                                  routeProvider: TrackingTestRouteProvider())
        XCTAssertTrue(model.isNavigationActive)
        XCTAssertTrue(model.rideActive)
        model.stopNavigation()
        XCTAssertEqual(source.stops, 0)
        model.stopRide()
        XCTAssertEqual(source.stops, 1)
    }

    @MainActor
    func testLocationStartFailureAndAsyncFailureAreSurfaced() async {
        let source = TrackingTestSource()
        source.failStart = true
        let model = AppModel(startsServices: false, locationSource: source, rideNow: { self.origin })
        model.startRide()
        XCTAssertEqual(model.rideSessionState, .inactive)
        XCTAssertNotNil(model.rideFailure)
        source.failStart = false
        model.startRide()
        source.fail?("GPS denied")
        XCTAssertEqual(model.rideFailure, "GPS denied")
        XCTAssertTrue(model.rideActive) // interruption doesn't silently end the Ride
        model.pauseRide()
        source.failStart = true
        model.resumeRide()
        XCTAssertEqual(model.rideSessionState, .paused)
        model.stopRide()
    }
}

@MainActor
private final class TrackingTestSource: NavigationLocationSource {
    var starts = 0
    var stops = 0
    var failStart = false
    private var callback: (@MainActor (NavigationFix) -> Void)?
    var fail: (@MainActor (String) -> Void)?
    func start(onFix: @escaping @MainActor (NavigationFix) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) throws {
        starts += 1
        if failStart { throw NavigationSourceError.permissionDenied }
        callback = onFix
        fail = onFailure
    }
    func stop() { stops += 1; callback = nil; fail = nil }
    func emit(_ fix: NavigationFix) { callback?(fix) }
}

private struct TrackingTestRouteProvider: NavigationRouteProviding {
    func route(for request: RouteRequest) async throws -> RouteEnvelope {
        // Deliberately no route geometry: these tests exercise startup/ownership.
        throw NavigationSourceError.unavailable("Test route service unavailable")
    }
}
