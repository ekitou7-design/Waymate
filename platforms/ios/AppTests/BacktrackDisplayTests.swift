import XCTest
@testable import Waymate

@MainActor
final class BacktrackDisplayTests: XCTestCase {
    typealias T = BacktrackTestTrail
    func testProjectionUsesSnapshotUUIDAndGeneration() throws {
        var cache = BLEBacktrackStateCache()
        let session = BacktrackSession(route: try T.route())
        cache.update(session: session, paused: false, page: .backtrack)
        XCTAssertEqual(cache.identity, session.route.id)
        XCTAssertEqual(cache.state?.identity.count, 16)
        XCTAssertEqual(cache.generation, 1)
        let geometry = cache.geometry
        cache.update(session: session, paused: false, page: .compass)
        XCTAssertEqual(cache.generation, 1)
        XCTAssertEqual(cache.geometry, geometry)
        XCTAssertEqual(cache.state?.page, 2)
        cache.update(session: BacktrackSession(route: try T.route()), paused: false, page: .backtrack)
        XCTAssertEqual(cache.generation, 2)
        XCTAssertNotEqual(cache.identity, session.route.id)
    }
    func testProgressPreservesGeometryAndEndRetainsInactiveTombstone() throws {
        var cache = BLEBacktrackStateCache()
        var s = BacktrackSession(route: try T.route())
        cache.update(session: s, paused: false, page: .backtrack)
        let saved = cache.geometry, id = cache.state!.identity
        T.feed(&s, 100, time: 0); T.feed(&s, 90, time: 2)
        cache.update(session: s, paused: false, page: .compass)
        XCTAssertEqual(cache.geometry, saved)
        XCTAssertGreaterThan(cache.state!.progressM, 0)
        XCTAssertEqual(cache.state!.identity, id)
        cache.update(session: nil, paused: false, page: .speed)
        XCTAssertEqual(cache.state!.flags, 0)
        XCTAssertEqual(cache.state!.identity, id)
        XCTAssertEqual(cache.state!.page, 1)
        XCTAssertNil(cache.geometryInput(chunk: 0))
        XCTAssertNil(cache.geometry)
    }
    func testStateFlagsOffTrackArrivalAndInvalidLocation() throws {
        var cache = BLEBacktrackStateCache()
        var s = BacktrackSession(route: try T.route())
        T.feed(&s, 100, east: 40, time: 0)
        cache.update(session: s, paused: false, page: .backtrack)
        XCTAssertNotEqual(cache.state!.flags & 2, 0)
        XCTAssertNotEqual(cache.state!.flags & 8, 0)
        s.invalidate(.stale)
        cache.update(session: s, paused: false, page: .backtrack)
        XCTAssertEqual(cache.state!.flags & 8, 0)
        XCTAssertEqual(cache.state!.targetDistanceM, .max)
        XCTAssertEqual(cache.state!.directionCentiDegrees, .max)
        var arrived = BacktrackSession(route: try T.route())
        for i in 0...10 { T.feed(&arrived, Double(100-i*10), time: Double(i*2)) }
        cache.update(session: arrived, paused: false, page: .backtrack)
        XCTAssertNotEqual(cache.state!.flags & 4, 0)
        XCTAssertEqual(cache.state!.remainingDistanceM, 0)
    }
    func testArrowRelativeOnlyWithRealUsableCourse() throws {
        var cache = BLEBacktrackStateCache()
        var s = BacktrackSession(route: try T.route())
        T.feed(&s, 100, time: 0, course: nil)
        cache.update(session: s, paused: false, page: .backtrack)
        XCTAssertEqual(cache.state!.flags & 16, 0)
        XCTAssertEqual(cache.state!.directionCentiDegrees, cache.state!.targetBearingCentiDegrees)
        T.feed(&s, 90, time: 2, course: 180)
        cache.update(session: s, paused: false, page: .backtrack)
        XCTAssertNotEqual(cache.state!.flags & 16, 0)
        XCTAssertEqual(cache.state!.directionCentiDegrees, 0)
        cache.update(session: s, paused: true, page: .backtrack)
        XCTAssertNotEqual(cache.state!.flags & 64, 0)
        XCTAssertEqual(cache.state!.flags & 8, 0)
        XCTAssertEqual(cache.state!.directionCentiDegrees, .max)
    }
    func testSingleAndMultipleSegmentsPreserveEndpointsAndGaps() throws {
        let track = T.straight() + T.track([T.point(500), T.point(550), T.point(600)], segment: 1)
        let route = try T.route(track)
        let geometry = BacktrackDisplayGeometry(route: route)
        XCTAssertEqual(Set(geometry.points.map(\.segment)), [0, 1])
        for index in route.segments.indices {
            let selected = geometry.points.filter { $0.segment == UInt16(index) }
            XCTAssertEqual(selected.first?.coordinate, route.segments[index].points.first)
            XCTAssertEqual(selected.last?.coordinate, route.segments[index].points.last)
        }
        XCTAssertEqual(geometry.points.last?.progressM, 200)
        XCTAssertEqual(route.segments.count, 2)
    }
    func testTooManyMandatoryEndpointsReportsUnavailable() throws {
        let track = (0..<130).flatMap { segment in T.track([T.point(Double(segment*20)), T.point(Double(segment*20+10))], segment: segment) }
        let s = BacktrackSession(route: try T.route(track))
        var cache = BLEBacktrackStateCache()
        cache.update(session: s, paused: false, page: .backtrack)
        XCTAssertFalse(cache.geometry!.available)
        XCTAssertNotEqual(cache.state!.flags & 128, 0)
    }
    func testBoundedGeometryCodecChunkingAndCosts() throws {
        let codec = MotoBLEProtocolCodec(maximumFrameSize: 182)
        for count in [100, 1000, 7000] {
            let track = T.track((0..<count).map { T.point(Double($0)*5, east: sin(Double($0)/25)*30) })
            let s = BacktrackSession(route: try T.route(track))
            let start = ContinuousClock().now
            var cache = BLEBacktrackStateCache()
            cache.update(session: s, paused: false, page: .backtrack)
            let elapsed = start.duration(to: ContinuousClock().now)
            XCTAssertLessThanOrEqual(cache.geometry!.points.count, 256)
            var chunk = 0, frames = 0, bytes = 0
            while let input = cache.geometryInput(chunk: chunk) {
                XCTAssertLessThanOrEqual(input.points.count, 24)
                let encoded = try codec.encodeBacktrackGeometry(input)
                frames += encoded.count; bytes += encoded.reduce(0) { $0 + $1.count }
                XCTAssertTrue(encoded.allSatisfy { $0[2] == 0x16 })
                chunk += 1
            }
            let state = try codec.encodeBacktrackState(cache.state!)
            XCTAssertTrue(state.allSatisfy { $0[2] == 0x15 })
            print("[BacktrackDisplay] source=\(count) display=\(cache.geometry!.points.count) tolerance=\(cache.geometry!.toleranceM)m chunks=\(chunk) frames182=\(frames) bytes=\(bytes) simplify=\(elapsed)")
        }
    }
    func testPathologicalSevenThousandPointZigzagIsBoundedDisplayOnly() throws {
        let route = try T.route(T.track((0..<7000).map { T.point(Double($0)*5, east: Double($0%2)*40) }))
        let before = route
        let start = ContinuousClock().now
        let geometry = BacktrackDisplayGeometry(route: route)
        print("[BacktrackDisplay] 7000 zigzag display=\(geometry.points.count) tolerance=\(geometry.toleranceM)m simplify=\(start.duration(to: ContinuousClock().now))")
        XCTAssertLessThanOrEqual(geometry.points.count, 256)
        XCTAssertEqual(geometry.points.first?.coordinate, route.segments[0].points.first)
        XCTAssertEqual(geometry.points.last?.coordinate, route.rideStart)
        XCTAssertEqual(route, before)
    }
    func testSmallMTUMaxChunkFitsQueueAndACKRetryUsesNewSequence() throws {
        let track = T.track((0..<300).map { T.point(Double($0)*5, east: Double($0%2)*40) })
        var cache = BLEBacktrackStateCache()
        cache.update(session: BacktrackSession(route: try T.route(track)), paused: false, page: .backtrack)
        let codec = MotoBLEProtocolCodec(maximumFrameSize: 20)
        let input = cache.geometryInput(chunk: 0)!
        let first = try codec.encodeBacktrackGeometry(input)
        XCTAssertLessThan(first.count + 32, 128)
        let firstSequence = codec.lastEncodedSequence
        let retry = try codec.encodeBacktrackGeometry(input)
        XCTAssertGreaterThan(codec.lastEncodedSequence, firstSequence)
        XCTAssertEqual(first.count, retry.count)
        XCTAssertEqual(cache.geometryInput(chunk: 0)!.identity, input.identity)
    }
    func testProductionDeliveryACKOrderingProgressDedupAndReconnect() throws {
        var cache = BLEBacktrackStateCache()
        var session = BacktrackSession(route: try T.route(T.track((0..<100).map { T.point(Double($0)*5, east: Double($0%2)*40) })))
        cache.update(session: session, paused: false, page: .backtrack)
        let id = cache.identity, geometry = cache.geometry, generation = cache.generation
        let codec = MotoBLEProtocolCodec(maximumFrameSize: 20)
        var delivery = BLEBacktrackGeometryDelivery()
        XCTAssertTrue(delivery.shouldSend(queuedFrames: 0))
        let first = try codec.encodeBacktrackGeometry(cache.geometryInput(chunk: 0)!)
        let seq = codec.lastEncodedSequence
        delivery.queued(frames: first, sequence: seq)
        XCTAssertFalse(delivery.shouldSend(queuedFrames: 0))
        delivery.expire(nowMs: 5000) // Queue time is NOT send time.
        XCTAssertFalse(delivery.shouldSend(queuedFrames: 0))
        for frame in first { delivery.written(frame, nowMs: 10000) }
        delivery.expire(nowMs: 13000)
        XCTAssertTrue(delivery.shouldSend(queuedFrames: 0))
        let retry = try codec.encodeBacktrackGeometry(cache.geometryInput(chunk: 0)!)
        delivery.queued(frames: retry, sequence: codec.lastEncodedSequence)
        XCTAssertFalse(delivery.acknowledge(sequence: seq, status: 0))
        XCTAssertTrue(delivery.acknowledge(sequence: codec.lastEncodedSequence, status: 4))
        XCTAssertEqual(delivery.chunk, 1)
        while let input = cache.geometryInput(chunk: delivery.chunk) {
            let frames = try codec.encodeBacktrackGeometry(input)
            delivery.queued(frames: frames, sequence: codec.lastEncodedSequence)
            XCTAssertTrue(delivery.acknowledge(sequence: codec.lastEncodedSequence, status: 0))
        }
        for time in 0..<100 {
            T.feed(&session, 495-Double(time)*5, east: Double((99-time)%2)*40, time: Double(time*2))
            cache.update(session: session, paused: false, page: .compass)
            XCTAssertNil(cache.geometryInput(chunk: delivery.chunk)) // No ordinary progress resend.
        }
        delivery = BLEBacktrackGeometryDelivery() // The production teardown/reset operation.
        XCTAssertNotNil(cache.geometryInput(chunk: delivery.chunk))
        XCTAssertEqual(cache.identity, id)
        XCTAssertEqual(cache.generation, generation)
        XCTAssertEqual(cache.geometry, geometry)
        let progress = cache.state!.progressM
        XCTAssertGreaterThan(progress, 0)
        XCTAssertEqual(cache.state!.page, 2)
        cache.update(session: nil, paused: false, page: .speed)
        delivery = BLEBacktrackGeometryDelivery()
        XCTAssertNil(cache.geometryInput(chunk: delivery.chunk))
        XCTAssertEqual(cache.state!.flags, 0) // Expired session cannot be restored.
    }

    func testLegacyPeerKeepsOriginalPageSelectionPackets() throws {
        var cache = BLEBacktrackStateCache()
        let session = BacktrackSession(route: try T.route())
        cache.update(session: session, paused: false, page: .backtrack)
        XCTAssertFalse(cache.usesIndependentState(peerCapabilities: 0))
        XCTAssertFalse(cache.usesIndependentState(peerCapabilities: 255))
        XCTAssertTrue(cache.usesIndependentState(peerCapabilities: 256))
        let central = ESP32BLECentral(), snapshot = MotoNavCoreBridge().snapshot
        let codec = MotoBLEProtocolCodec(maximumFrameSize: 182)
        central.sendBacktrack(session: session, paused: false, page: .backtrack)
        central.sendNavigationSnapshot(snapshot, displayPage: .backtrack)
        XCTAssertEqual(central.makeSnapshotInput(snapshot, codec: codec).displayPageName, "speed")
        central.sendNavigationSnapshot(snapshot, displayPage: .music)
        XCTAssertEqual(central.makeSnapshotInput(snapshot, codec: codec).displayPageName, "music")
        central.sendNavigationSnapshot(snapshot, displayPage: .compass)
        XCTAssertEqual(central.makeSnapshotInput(snapshot, codec: codec).displayPageName, "compass")
        cache.update(session: nil, paused: false, page: .speed)
        XCTAssertFalse(cache.usesIndependentState(peerCapabilities: 256))
    }

    func testArrivedReclaimsOnceAndEndChoosesRideOrReady() {
        let id = UUID(), d = PresentationDriver(schedulesExpiry: false)
        let state = BacktrackComponentState(routeIdentity: id, offTrack: false, arrived: false, paused: false, locationValidity: .usable, urgentEventIdentity: nil)
        d.update(navigation: nil, rideActive: true, backtrack: state)
        d.manuallySelect(rawValue: 3)
        d.update(navigation: nil, rideActive: true, backtrack: state)
        XCTAssertEqual(d.selectedPage, .music)
        let arrived = BacktrackComponentState(routeIdentity: id, offTrack: false, arrived: true, paused: false, locationValidity: .usable, urgentEventIdentity: nil)
        d.update(navigation: nil, rideActive: true, backtrack: arrived)
        XCTAssertEqual(d.selectedPage, .backtrack)
        d.manuallySelect(rawValue: 2)
        d.update(navigation: nil, rideActive: true, backtrack: arrived)
        XCTAssertEqual(d.selectedPage, .compass)
        d.update(navigation: nil, rideActive: true)
        XCTAssertEqual(d.selectedPage, .speed)
        d.update(navigation: nil, rideActive: false)
        XCTAssertEqual(d.selectedPage, .navigation)
    }
}
