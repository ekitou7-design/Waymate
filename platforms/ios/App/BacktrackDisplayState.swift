import Foundation
import MotoNavigationCore

/// Display-only projection. Does not alter the source snapshot or perform guidance.
struct BacktrackDisplayGeometry: Equatable {
    struct Point: Equatable {
        let coordinate: WGS84Point
        let progressM: UInt32
        let segment: UInt16
    }
    let points: [Point]
    let toleranceM: Double
    var available: Bool { !points.isEmpty }

    init(route: BacktrackRoute) {
        let mandatory = route.segments.reduce(0) { $0 + min(2, $1.points.count) }
        guard mandatory <= 256, route.segments.count <= Int(UInt16.max) else {
            points = []; toleranceM = 0; return
        }
        // Metric coordinates are display-only. Actual WGS84 points and their
        // original cumulative distances are retained in the emitted projection.
        let metric = route.segments.map { segment in
            let origin = segment.points[0]
            let scale = cos(BreadcrumbMath.radians(origin.latitudeDeg)) * BreadcrumbMath.radius
            return segment.points.map { p in
                (BreadcrumbMath.radians(BreadcrumbMath.wrapped(p.longitudeDeg-origin.longitudeDeg)) * scale,
                 BreadcrumbMath.radians(p.latitudeDeg-origin.latitudeDeg) * BreadcrumbMath.radius)
            }
        }
        let workLimit = route.segments.reduce(0) { $0 + $1.points.count } * 128
        var tolerance = 3.0
        var result: [Point] = []
        var exceeded = false
        repeat {
            result = []; exceeded = false
            var work = 0
            for (segmentIndex, segment) in route.segments.enumerated() {
                var retained: Set<Int> = [0, segment.points.count - 1]
                var stack = segment.points.count > 2 ? [(0, segment.points.count - 1)] : []
                let xy = metric[segmentIndex]
                while let (first, last) = stack.popLast() {
                    guard last > first + 1 else { continue }
                    let dx = xy[last].0-xy[first].0, dy = xy[last].1-xy[first].1
                    let denominator = dx*dx+dy*dy
                    var furthest = first, distance = tolerance*tolerance
                    for index in (first + 1)..<last {
                        work += 1
                        // ponytail: bounded RDP work; increase display tolerance
                        // for pathological zigzags instead of blocking the main actor.
                        if work > workLimit { exceeded = true; break }
                        let x = xy[index].0-xy[first].0, y = xy[index].1-xy[first].1
                        let f = denominator > 0 ? min(1, max(0, (x*dx+y*dy)/denominator)) : 0
                        let d = (x-f*dx)*(x-f*dx)+(y-f*dy)*(y-f*dy)
                        if d > distance { furthest = index; distance = d }
                    }
                    if exceeded { break }
                    if furthest != first {
                        retained.insert(furthest)
                        if retained.count + result.count > 256 { exceeded = true; break }
                        stack.append((first, furthest)); stack.append((furthest, last))
                    }
                }
                if exceeded { break }
                for index in retained.sorted() {
                    result.append(.init(coordinate: segment.points[index],
                                        progressM: Self.distance(segment.offset + segment.cumulative[index]),
                                        segment: UInt16(segmentIndex)))
                }
            }
            if exceeded || result.count > 256 { tolerance *= 2 }
        } while exceeded || result.count > 256
        points = result; toleranceM = tolerance
    }

    static func distance(_ value: Double?) -> UInt32 {
        guard let value, value.isFinite, value >= 0 else { return .max }
        return UInt32(min(Double(UInt32.max - 1), value.rounded()))
    }
}

/// Keeps the immutable display geometry once per UUID, and an End tombstone.
/// Connection loss changes delivery bookkeeping only, never this projection.
struct BLEBacktrackStateCache {
    private(set) var identity: UUID?
    private(set) var generation: UInt32 = 0
    private(set) var geometry: BacktrackDisplayGeometry?
    private(set) var state: MotoBLEBacktrackStateInput?
    func usesIndependentState(peerCapabilities: UInt32) -> Bool {
        (state?.flags ?? 0) & 1 != 0 && peerCapabilities & (1 << 8) != 0
    }

    mutating func update(session: BacktrackSession?, paused: Bool, page: RoundDisplayPage) {
        if let session {
            if identity != session.route.id {
                identity = session.route.id
                generation &+= 1
                if generation == 0 { generation = 1 }
                geometry = BacktrackDisplayGeometry(route: session.route)
            }
            let p = session.progress
            let input = base(page: page)
            input.flags = 1
            if p.offTrack { input.flags |= 2 }
            if p.arrived { input.flags |= 4 }
            let usable = !paused && p.locationValidity == .usable
            if usable { input.flags |= 8 }
            if usable, p.relativeDirection != nil { input.flags |= 16 }
            if p.trailGap { input.flags |= 32 }
            if paused { input.flags |= 64 }
            if geometry?.available != true { input.flags |= 128 }
            input.remainingDistanceM = BacktrackDisplayGeometry.distance(p.remainingDistance)
            input.targetDistanceM = usable ? BacktrackDisplayGeometry.distance(p.distanceToTarget) : .max
            input.progressM = BacktrackDisplayGeometry.distance(session.route.length - p.remainingDistance)
            input.targetBearingCentiDegrees = usable ? Self.direction(p.targetBearing) : .max
            input.directionCentiDegrees = usable ? Self.direction(p.relativeDirection ?? p.targetBearing) : .max
            if let position = p.currentPosition {
                input.latitudeE6 = Int32((position.latitudeDeg * 1e6).rounded())
                input.longitudeE6 = Int32((position.longitudeDeg * 1e6).rounded())
            }
            state = input
        } else if identity != nil {
            let input = base(page: page == .backtrack ? .speed : page)
            input.flags = 0
            state = input
            geometry = nil
        }
    }

    private func base(page: RoundDisplayPage) -> MotoBLEBacktrackStateInput {
        let input = MotoBLEBacktrackStateInput()
        var bytes = identity!.uuid
        input.identity = withUnsafeBytes(of: &bytes) { Data($0) }
        input.generation = generation
        input.page = page.rawValue
        input.targetDistanceM = .max
        input.targetBearingCentiDegrees = .max
        input.directionCentiDegrees = .max
        return input
    }
    private static func direction(_ value: Double?) -> UInt16 {
        guard let value, value.isFinite else { return .max }
        let normalized = (value.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return UInt16(Int((normalized * 100).rounded()) % 36000)
    }
    func geometryInput(chunk: Int) -> MotoBLEBacktrackGeometryInput? {
        guard let geometry, geometry.available, let state else { return nil }
        let first = chunk * 24
        guard first < geometry.points.count else { return nil }
        let input = MotoBLEBacktrackGeometryInput()
        input.identity = state.identity
        input.generation = generation
        input.chunkIndex = UInt16(chunk)
        input.totalPointCount = UInt16(geometry.points.count)
        input.points = geometry.points[first..<min(first + 24, geometry.points.count)].map { source in
            let point = MotoBLEBacktrackPointInput()
            point.latitudeE6 = Int32((source.coordinate.latitudeDeg * 1e6).rounded())
            point.longitudeE6 = Int32((source.coordinate.longitudeDeg * 1e6).rounded())
            point.progressM = source.progressM
            point.segmentIndex = source.segment
            return point
        }
        return input
    }
}

/// One ACK-tracked geometry chunk at a time. Uses the existing map delivery
/// timeout/retry machinery; ordinary progress has no geometry reset operation.
struct BLEBacktrackGeometryDelivery {
    private var receipt = BLEMapSceneDelivery()
    private(set) var chunk = 0
    private var finalFrame: Data?
    var timeoutCount: Int { receipt.timeoutCount }
    func shouldSend(queuedFrames: Int) -> Bool {
        receipt.shouldSend(revision: UInt32(chunk + 1), queuedFrames: queuedFrames)
    }
    mutating func queued(frames: [Data], sequence: UInt16) {
        finalFrame = frames.last
        receipt.queued(revision: UInt32(chunk + 1), sequence: sequence)
    }
    mutating func written(_ frame: Data, nowMs: UInt64) {
        if frame == finalFrame {
            finalFrame = nil
            receipt.lastFragmentWritten(nowMs: nowMs)
        }
    }
    @discardableResult
    mutating func acknowledge(sequence: UInt16, status: UInt8) -> Bool {
        guard receipt.acknowledge(sequence: sequence, status: status) else { return false }
        finalFrame = nil
        if status == 0 || status == 4 { chunk += 1 }
        return true
    }
    mutating func expire(nowMs: UInt64) { receipt.expire(nowMs: nowMs) }
}
