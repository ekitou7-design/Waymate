import Foundation
import MotoNavigationCore
import XCTest
@testable import Waymate

/// Synthetic observations live in AppTests only; they never seed the production recorder.
enum BacktrackTestTrail {
    static let start = Date(timeIntervalSince1970: 10_000)
    static func point(_ north: Double, east: Double = 0) -> WGS84Point {
        .init(longitudeDeg: 117 + east / (BreadcrumbMath.radius * cos(.pi / 5)) * 180 / .pi,
              latitudeDeg: 36 + north / BreadcrumbMath.radius * 180 / .pi)
    }
    static func track(_ coordinates: [WGS84Point], segment: Int = 0, time: Double = 0) -> [RideTrackPoint] {
        coordinates.enumerated().map { i, p in
            .init(latitude: p.latitudeDeg, longitude: p.longitudeDeg,
                  timestamp: start.addingTimeInterval(time + Double(i) * 2), horizontalAccuracy: 3, speed: 5, segment: segment)
        }
    }
    static func straight(_ length: Int = 100) -> [RideTrackPoint] {
        track(stride(from: 0, through: length, by: 10).map { point(Double($0)) })
    }
    static func route(_ track: [RideTrackPoint]? = nil) throws -> BacktrackRoute {
        try .build(track: track ?? straight(), sourceRideStartedAt: start)
    }
    static func fix(_ north: Double, east: Double = 0, time: Double,
                    accuracy: Double = 3, speed: Double? = 5, course: Double? = 180) -> NavigationFix {
        .init(coordinate: point(north, east: east), horizontalAccuracyM: accuracy,
              speedMps: speed, courseDeg: course, timestamp: start.addingTimeInterval(time))
    }
    static func feed(_ session: inout BacktrackSession, _ north: Double, east: Double = 0,
                     time: Double, accuracy: Double = 3, speed: Double? = 5, course: Double? = 180) {
        let fix = fix(north, east: east, time: time, accuracy: accuracy, speed: speed, course: course)
        session.update(fix, at: fix.timestamp)
    }
}

final class BacktrackRouteTests: XCTestCase {
    private typealias T = BacktrackTestTrail
    func testEmptyTrack() { XCTAssertThrowsError(try T.route([])) }
    func testSinglePoint() { XCTAssertThrowsError(try T.route(T.track([T.point(0)]))) }
    func testTwoFarPointsStillInsufficient() { XCTAssertThrowsError(try T.route(T.track([T.point(0), T.point(100)]))) }
    func testInsufficientDistanceAndStationaryDuplicates() {
        XCTAssertThrowsError(try T.route(T.straight(30)))
        XCTAssertThrowsError(try T.route(T.track(Array(repeating: T.point(0), count: 100))))
    }
    func testJitterWithAccumulatedDistanceButNoSpatialExtent() {
        let points = (0..<30).map { T.point($0 % 2 == 0 ? 0 : 5) }
        XCTAssertThrowsError(try T.route(T.track(points)))
    }
    func testSingleSegmentReversesPointOrderAndIdentity() throws {
        let track = T.straight()
        let route = try T.route(track)
        XCTAssertEqual(route.segments.count, 1)
        XCTAssertEqual(route.segments[0].points.map(\.latitudeDeg), track.reversed().map(\.latitude))
        XCTAssertEqual(route.rideStart, T.point(0))
        XCTAssertEqual(route.sourceRideStartedAt, T.start)
        XCTAssertEqual(route.length, 100, accuracy: 0.01)
        XCTAssertNotEqual(route.id, try T.route(track).id)
    }
    func testSegmentsReverseWithoutCountingGap() throws {
        let track = T.straight(50) + T.track([T.point(1_000), T.point(1_030), T.point(1_060)], segment: 1, time: 100)
        let route = try T.route(track)
        XCTAssertEqual(route.segments.count, 2)
        XCTAssertEqual(route.segments[0].points.first, T.point(1_060))
        XCTAssertEqual(route.segments[0].points.last, T.point(1_000))
        XCTAssertEqual(route.segments[1].points.first, T.point(50))
        XCTAssertEqual(route.length, 110, accuracy: 0.01)
        XCTAssertEqual(route.segments[1].offset, 60, accuracy: 0.01)
    }
    func testSingletonAndRepeatedSegmentIDsPreserved() throws {
        let track = T.straight(50) + T.track([T.point(100)], segment: 1, time: 100)
            + T.track([T.point(200), T.point(230)], segment: 0, time: 120)
        let route = try T.route(track)
        XCTAssertEqual(route.segments.map { $0.points.count }, [2, 1, 6])
        XCTAssertEqual(route.length, 80, accuracy: 0.01)
    }
    func testInvalidMiddlePointCreatesGapAndInvalidEndpointRejects() throws {
        var track = T.straight(200)
        track[10] = .init(latitude: .nan, longitude: 117, timestamp: T.start, horizontalAccuracy: 3, speed: 5, segment: 0)
        let route = try T.route(track)
        XCTAssertEqual(route.segments.count, 2)
        XCTAssertEqual(route.length, 180, accuracy: 0.01)
        track[0] = track[10]
        XCTAssertThrowsError(try T.route(track))
    }
    func testOriginalRecordAndSnapshotNotMutated() throws {
        var track = T.straight()
        let record = RideRecord(startedAt: T.start, endedAt: T.start.addingTimeInterval(30), elapsedTime: 30,
                                movingTime: 20, distance: 100, maxSpeed: 5, track: track)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(record)
        let route = try T.route(record.track)
        track += T.track([T.point(90), T.point(80)], time: 30)
        XCTAssertEqual(route.segments[0].points.count, 11)
        XCTAssertEqual(route.length, 100, accuracy: 0.01)
        XCTAssertEqual(try encoder.encode(record), before)
    }
    func testDatelineDistanceAndInterpolationStayLocal() throws {
        let a = WGS84Point(longitudeDeg: 179.999, latitudeDeg: 0)
        let b = WGS84Point(longitudeDeg: -179.999, latitudeDeg: 0)
        let m = BreadcrumbMath.interpolate(a, b, fraction: 0.5)
        let route = try T.route(T.track([a, m, b]))
        XCTAssertEqual(route.length, 222.39, accuracy: 0.1)
        XCTAssertEqual(abs(m.longitudeDeg), 180, accuracy: 0.00001)
        XCTAssertEqual(BreadcrumbMath.bearing(a, b)!, 90, accuracy: 0.01)
    }
}

final class BacktrackProgressTests: XCTestCase {
    private typealias T = BacktrackTestTrail
    private func session() throws -> BacktrackSession { .init(route: try T.route()) }
    func testStartsAtOutwardEndpointWithLookaheadAndBearing() throws {
        var s = try session()
        T.feed(&s, 100, time: 0)
        XCTAssertEqual(s.progress.remainingDistance, 100, accuracy: 0.01)
        XCTAssertEqual(s.progress.distanceToTarget!, 30, accuracy: 0.01)
        XCTAssertLessThan(BreadcrumbMath.distance(s.progress.target!, T.point(70)), 0.01)
        XCTAssertEqual(s.progress.targetBearing!, 180, accuracy: 0.01)
        XCTAssertEqual(s.progress.relativeDirection!, 0, accuracy: 0.01)
        XCTAssertFalse(s.progress.arrived)
    }
    func testMovesTowardStartAndRemainingUsesPolyline() throws {
        var s = try session()
        for (i, north) in [100.0, 90, 80, 70].enumerated() { T.feed(&s, north, time: Double(i) * 2) }
        XCTAssertEqual(s.progress.remainingDistance, 70, accuracy: 0.01)
        XCTAssertEqual(s.progress.segmentDistance, 30, accuracy: 0.01)
    }
    func testMonotonicJitterAndNearestPointBehind() throws {
        var s = try session(), previous = 0.0
        for (i, north) in [100.0, 90, 80, 82, 79, 81, 83, 70].enumerated() {
            T.feed(&s, north, time: Double(i) * 2)
            XCTAssertGreaterThanOrEqual(s.progress.segmentDistance, previous)
            previous = s.progress.segmentDistance
        }
        XCTAssertEqual(s.progress.segmentDistance, 30, accuracy: 0.01)
    }
    func testSelfIntersectingRouteDoesNotJumpToLaterCrossing() throws {
        let points = [T.point(0), T.point(100, east: 100), T.point(100, east: -100), T.point(0, east: 100), T.point(100)]
        var s = BacktrackSession(route: try T.route(T.track(points)))
        T.feed(&s, 100, time: 0)
        T.feed(&s, 90, east: 10, time: 2)
        XCTAssertLessThan(s.progress.segmentDistance, 25)
        XCTAssertEqual(s.progress.segmentIndex, 0)
        XCTAssertGreaterThan(s.progress.remainingDistance, 500)
    }
    func testLoopNearStartCannotArriveEarly() throws {
        let points = [T.point(0), T.point(100), T.point(100, east: 100), T.point(0, east: 100), T.point(0)]
        var s = BacktrackSession(route: try T.route(T.track(points)))
        T.feed(&s, 0, time: 0)
        XCTAssertFalse(s.progress.arrived)
        XCTAssertEqual(s.progress.segmentDistance, 0, accuracy: 0.01)
        XCTAssertGreaterThan(s.progress.remainingDistance, 390)
    }
    func testUTurnAndOverlappingTrailFollowSequentialEdges() throws {
        let norths = Array(stride(from: 0.0, through: 100, by: 10)) + Array(stride(from: 90.0, through: 0, by: -10))
        var s = BacktrackSession(route: try T.route(T.track(norths.map { T.point($0) })))
        for i in 0...5 { T.feed(&s, Double(i) * 10, time: Double(i) * 2) }
        XCTAssertEqual(s.progress.segmentDistance, 50, accuracy: 0.01)
        XCTAssertEqual(s.progress.remainingDistance, 150, accuracy: 0.01)
        XCTAssertFalse(s.progress.arrived)
        for i in 6...10 { T.feed(&s, Double(i) * 10, time: Double(i) * 2) }
        for i in 1...10 { T.feed(&s, 100 - Double(i) * 10, time: 20 + Double(i) * 2) }
        XCTAssertTrue(s.progress.arrived)
        XCTAssertEqual(s.progress.remainingDistance, 0)
    }
    func testDenseCrossingFollowsFullReverseTraversal() throws {
        let vertices = [T.point(0), T.point(120, east: 120), T.point(120, east: -120), T.point(0, east: 120), T.point(120)]
        var points = [vertices[0]]
        for index in 1..<vertices.count {
            let steps = Int(ceil(BreadcrumbMath.distance(vertices[index - 1], vertices[index]) / 10))
            for step in 1...steps {
                points.append(BreadcrumbMath.interpolate(vertices[index - 1], vertices[index], fraction: Double(step) / Double(steps)))
            }
        }
        var s = BacktrackSession(route: try T.route(T.track(points)))
        let reversed = Array(points.reversed())
        var covered = 0.0
        for (index, position) in reversed.enumerated() {
            if index > 0 { covered += BreadcrumbMath.distance(reversed[index - 1], position) }
            let fix = NavigationFix(coordinate: position, horizontalAccuracyM: 3, speedMps: 5,
                                    timestamp: T.start.addingTimeInterval(Double(index) * 2))
            s.update(fix, at: fix.timestamp)
            XCTAssertLessThanOrEqual(s.route.length - s.progress.remainingDistance, covered + 15)
            XCTAssertFalse(s.progress.offTrack)
        }
        XCTAssertTrue(s.progress.arrived)
    }
    func testSparseEdgeProjectionClipsAtWindowInsteadOfFalseOffTrack() throws {
        var s = BacktrackSession(route: try T.route(T.track([T.point(0), T.point(100), T.point(200)])))
        T.feed(&s, 200, time: 0, speed: 22)
        T.feed(&s, 134, time: 3, speed: 22)
        XCTAssertFalse(s.progress.offTrack)
        XCTAssertEqual(s.progress.segmentDistance, 60, accuracy: 0.01)
        XCTAssertEqual(s.progress.remainingDistance, 140, accuracy: 0.01)
        T.feed(&s, 124, time: 4, speed: 22)
        XCTAssertFalse(s.progress.offTrack)
        XCTAssertEqual(s.progress.remainingDistance, 124, accuracy: 0.01)
    }
    func testLargeGPSJumpDoesNotAdvanceAndRecoveryWorks() throws {
        var s = try session()
        T.feed(&s, 100, time: 0)
        T.feed(&s, 0, time: 1)
        XCTAssertEqual(s.progress.locationValidity, .jumpRejected)
        XCTAssertEqual(s.progress.segmentDistance, 0)
        XCTAssertFalse(s.progress.arrived)
        T.feed(&s, 90, time: 2)
        XCTAssertEqual(s.progress.locationValidity, .usable)
        XCTAssertEqual(s.progress.segmentDistance, 10, accuracy: 0.01)
    }
    func testPoorAccuracyCannotAdvanceOrArrive() throws {
        var s = try session()
        T.feed(&s, 100, time: 0)
        T.feed(&s, 80, time: 2, accuracy: 40)
        XCTAssertEqual(s.progress.segmentDistance, 0)
        XCTAssertFalse(s.progress.offTrack)
        T.feed(&s, 0, time: 4, accuracy: 100)
        XCTAssertEqual(s.progress.locationValidity, .poorAccuracy)
        XCTAssertFalse(s.progress.arrived)
        XCTAssertNil(s.progress.targetBearing)
    }
    func testStaleFutureInvalidAndOutOfOrderFixes() throws {
        var s = try session()
        T.feed(&s, 100, time: 2)
        let good = s
        T.feed(&s, 90, time: 1)
        XCTAssertEqual(s, good)
        let old = T.fix(90, time: 3)
        s.update(old, at: T.start.addingTimeInterval(20))
        XCTAssertEqual(s.progress.locationValidity, .stale)
        s.update(T.fix(90, time: 30), at: T.start.addingTimeInterval(10))
        XCTAssertEqual(s.progress.segmentDistance, 0)
        s.refresh(at: T.start.addingTimeInterval(30))
        XCTAssertNil(s.progress.distanceToTarget)
        let invalid = NavigationFix(coordinate: .init(longitudeDeg: .nan, latitudeDeg: 36), horizontalAccuracyM: 3, timestamp: T.start)
        s.update(invalid, at: T.start)
        XCTAssertEqual(s.progress.segmentDistance, 0)
    }
    func testSlightDeviationAndOffTrackAccuracyHysteresis() throws {
        var s = try session()
        T.feed(&s, 100, time: 0)
        T.feed(&s, 100, east: 20, time: 2)
        XCTAssertFalse(s.progress.offTrack)
        T.feed(&s, 100, east: 35, time: 4)
        XCTAssertTrue(s.progress.offTrack)
        XCTAssertEqual(s.progress.target!, T.point(100))
        T.feed(&s, 100, east: 20, time: 6)
        XCTAssertTrue(s.progress.offTrack) // rejoin threshold is smaller
        T.feed(&s, 100, east: 5, time: 8)
        XCTAssertFalse(s.progress.offTrack)
    }
    func testPoorAccuracyRaisesDeviationThreshold() throws {
        var s = try session()
        T.feed(&s, 100, east: 35, time: 0, accuracy: 40)
        XCTAssertFalse(s.progress.offTrack)
        XCTAssertEqual(s.progress.segmentDistance, 0)
        XCTAssertNil(s.progress.relativeDirection)
    }
    func testOffTrackEventIdentityStableUntilNewTransition() throws {
        var s = try session()
        T.feed(&s, 100, east: 35, time: 0)
        let first = s.component(paused: false).urgentEventIdentity
        XCTAssertNotNil(first)
        T.feed(&s, 100, east: 36, time: 2)
        XCTAssertEqual(first, s.component(paused: false).urgentEventIdentity)
        T.feed(&s, 100, time: 4)
        XCTAssertNil(s.component(paused: false).urgentEventIdentity)
        T.feed(&s, 100, east: 35, time: 6)
        XCTAssertNotEqual(first, s.component(paused: false).urgentEventIdentity)
    }
    func testCourseIsNotBearingAndUnavailableCourseUsesAbsoluteDirection() throws {
        for (speed, course) in [(0.0, 180.0), (5, -1), (5, Double.nan), (5, 360)] {
            var s = try session()
            T.feed(&s, 100, time: 0, speed: speed, course: course)
            XCTAssertEqual(s.progress.targetBearing!, 180, accuracy: 0.01)
            XCTAssertNil(s.progress.relativeDirection)
        }
        var s = try session()
        T.feed(&s, 100, time: 0, course: 90)
        XCTAssertEqual(s.progress.relativeDirection!, 90, accuracy: 0.01)
    }
    func testSegmentAndGapTransitionDoNotCountGapOrConnectMap() throws {
        let track = T.straight(50) + T.track([T.point(100), T.point(110), T.point(120), T.point(130)], segment: 1, time: 30)
        var s = BacktrackSession(route: try T.route(track))
        for (i, north) in [130.0, 120, 110, 100].enumerated() { T.feed(&s, north, time: Double(i) * 2) }
        XCTAssertTrue(s.progress.trailGap)
        XCTAssertEqual(s.progress.remainingDistance, 50, accuracy: 0.01)
        XCTAssertEqual(s.progress.target!, T.point(50))
        T.feed(&s, 75, time: 8)
        XCTAssertTrue(s.progress.trailGap)
        XCTAssertEqual(s.progress.remainingDistance, 50, accuracy: 0.01)
        T.feed(&s, 50, time: 10)
        XCTAssertFalse(s.progress.trailGap)
        XCTAssertEqual(s.progress.segmentIndex, 1)
        T.feed(&s, 40, time: 12)
        XCTAssertEqual(s.progress.remainingDistance, 40, accuracy: 0.01)
        let completed = BacktrackMapGeometry(route: s.route, progress: s.progress).completed
        XCTAssertEqual(completed.count, 2)
        XCTAssertEqual(completed[0].last, T.point(100))
        XCTAssertEqual(completed[1].first, T.point(50))
    }
    func testLookaheadNeverCrossesGap() throws {
        var s = BacktrackSession(route: try T.route(T.straight(50) + T.track([T.point(100), T.point(110)], segment: 1, time: 30)))
        T.feed(&s, 110, time: 0)
        XCTAssertEqual(s.progress.target, T.point(100))
        XCTAssertEqual(s.progress.distanceToTarget!, 10, accuracy: 0.01)
    }
    func testFinalArrivalIsStickyAndEndsOnlyGuidanceProgress() throws {
        var s = try session()
        for i in 0...10 { T.feed(&s, 100 - Double(i) * 10, time: Double(i) * 2) }
        XCTAssertTrue(s.progress.arrived)
        XCTAssertEqual(s.progress.remainingDistance, 0)
        T.feed(&s, 30, time: 24)
        XCTAssertTrue(s.progress.arrived)
        XCTAssertEqual(s.progress.remainingDistance, 0)
    }
    func testRemainingTrailDistanceIsNotStraightDistanceToStart() throws {
        let points = [T.point(0), T.point(100), T.point(100, east: 100)]
        var s = BacktrackSession(route: try T.route(T.track(points)))
        T.feed(&s, 100, east: 100, time: 0)
        XCTAssertEqual(s.progress.remainingDistance, 200, accuracy: 0.02)
        XCTAssertLessThan(BreadcrumbMath.distance(T.point(100, east: 100), s.route.rideStart), 150)
    }
    func testSevenThousandPointPerformance() throws {
        let track = T.track((0..<7_200).map { T.point(Double($0) * 5) })
        let before = ContinuousClock().now
        var s = BacktrackSession(route: try T.route(track))
        let construction = before.duration(to: ContinuousClock().now)
        let begin = ContinuousClock().now
        for i in 0..<1_000 { T.feed(&s, Double(7_199 - i) * 5, time: Double(i) * 2) }
        let duration = begin.duration(to: ContinuousClock().now)
        XCTAssertEqual(s.route.segments[0].points.count, 7_200)
        XCTAssertEqual(s.progress.segmentDistance, 4_995, accuracy: 0.01)
        let attachment = XCTAttachment(string: "7200 points; build=\(construction); 1000 sequential updates=\(duration); each search <=53 edges + O(log n) lookups")
        attachment.name = "Backtrack performance"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[Backtrack performance] build=\(construction) 1000 updates=\(duration)")
    }
}
