import Foundation
import MotoNavigationCore

/// Local WGS84 calculations. No road matching, provider or platform callbacks.
enum BreadcrumbMath {
    static let radius = 6_371_000.0
    static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    static func wrapped(_ degrees: Double) -> Double {
        var result = degrees.truncatingRemainder(dividingBy: 360)
        if result > 180 { result -= 360 }
        if result < -180 { result += 360 }
        return result
    }
    static func valid(_ p: WGS84Point) -> Bool {
        p.isValid
    }
    static func distance(_ a: WGS84Point, _ b: WGS84Point) -> Double {
        let lat = radians(b.latitudeDeg - a.latitudeDeg)
        let lon = radians(wrapped(b.longitudeDeg - a.longitudeDeg))
        let h = pow(sin(lat / 2), 2) + cos(radians(a.latitudeDeg)) * cos(radians(b.latitudeDeg)) * pow(sin(lon / 2), 2)
        return radius * 2 * asin(sqrt(min(1, max(0, h))))
    }
    static func bearing(_ a: WGS84Point, _ b: WGS84Point) -> Double? {
        guard distance(a, b) > 1 else { return nil }
        let lon = radians(wrapped(b.longitudeDeg - a.longitudeDeg))
        let y = sin(lon) * cos(radians(b.latitudeDeg))
        let x = cos(radians(a.latitudeDeg)) * sin(radians(b.latitudeDeg))
            - sin(radians(a.latitudeDeg)) * cos(radians(b.latitudeDeg)) * cos(lon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
    static func interpolate(_ a: WGS84Point, _ b: WGS84Point, fraction: Double) -> WGS84Point {
        .init(longitudeDeg: wrapped(a.longitudeDeg + wrapped(b.longitudeDeg - a.longitudeDeg) * fraction),
              latitudeDeg: a.latitudeDeg + (b.latitudeDeg - a.latitudeDeg) * fraction)
    }
    /// Tangent-plane projection for one short recorded edge, with date-line wrapping.
    static func projection(_ p: WGS84Point, _ a: WGS84Point, _ b: WGS84Point) -> (fraction: Double, point: WGS84Point, distance: Double) {
        let scale = cos(radians((a.latitudeDeg + b.latitudeDeg) / 2))
        let bx = radians(wrapped(b.longitudeDeg - a.longitudeDeg)) * scale * radius
        let by = radians(b.latitudeDeg - a.latitudeDeg) * radius
        let px = radians(wrapped(p.longitudeDeg - a.longitudeDeg)) * scale * radius
        let py = radians(p.latitudeDeg - a.latitudeDeg) * radius
        let lengthSquared = bx * bx + by * by
        let f = lengthSquared > 0 ? min(1, max(0, (px * bx + py * by) / lengthSquared)) : 0
        let projected = interpolate(a, b, fraction: f)
        return (f, projected, distance(p, projected))
    }
}

struct BacktrackRoute: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        let points: [WGS84Point]
        let cumulative: [Double]
        let offset: Double
        var length: Double { cumulative.last ?? 0 }
        /// Binary search also keeps target lookup bounded on a long segment.
        func edge(at distance: Double) -> Int {
            guard points.count > 1 else { return 0 }
            var low = 0, high = cumulative.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if cumulative[mid] <= distance { low = mid } else { high = mid - 1 }
            }
            return min(low, points.count - 2)
        }
        func point(at distance: Double) -> WGS84Point {
            let index = edge(at: distance)
            guard points.count > 1 else { return points[0] }
            let length = cumulative[index + 1] - cumulative[index]
            return BreadcrumbMath.interpolate(points[index], points[index + 1],
                fraction: length > 0 ? min(1, max(0, (distance - cumulative[index]) / length)) : 0)
        }
    }
    enum BuildError: Error, Equatable { case insufficientTrail, invalidEndpoint }
    let id: UUID
    /// Active Ride has no UUID until stop; its actual start instant identifies the source.
    let sourceRideStartedAt: Date
    let segments: [Segment]
    let length: Double
    var rideStart: WGS84Point { segments.last!.points.last! }

    private init(id: UUID, sourceRideStartedAt: Date, segments: [Segment], length: Double) {
        self.id = id
        self.sourceRideStartedAt = sourceRideStartedAt
        self.segments = segments
        self.length = length
    }

    static func isEligible(track: [RideTrackPoint]) -> Bool {
        (try? build(track: track, sourceRideStartedAt: .distantPast)) != nil
    }
    static func build(track: [RideTrackPoint], sourceRideStartedAt: Date) throws -> Self {
        func usable(_ p: RideTrackPoint) -> Bool {
            BreadcrumbMath.valid(.init(longitudeDeg: p.longitude, latitudeDeg: p.latitude))
                && p.horizontalAccuracy.isFinite && (0...50).contains(p.horizontalAccuracy)
                && p.timestamp.timeIntervalSince1970.isFinite
        }
        guard !track.isEmpty else { throw BuildError.insufficientTrail }
        guard usable(track[0]), usable(track[track.count - 1]) else { throw BuildError.invalidEndpoint }
        var runs: [[WGS84Point]] = [], run: [WGS84Point] = []
        var previous: RideTrackPoint?
        for p in track {
            if !usable(p) || previous?.segment != p.segment {
                if !run.isEmpty { runs.append(run) }
                run = []
            }
            if usable(p) { run.append(.init(longitudeDeg: p.longitude, latitudeDeg: p.latitude)) }
            previous = usable(p) ? p : nil
        }
        if !run.isEmpty { runs.append(run) }
        var segments: [Segment] = [], total = 0.0
        for run in runs.reversed() {
            let points = Array(run.reversed())
            var cumulative = [0.0]
            for index in 1..<points.count {
                cumulative.append(cumulative.last! + BreadcrumbMath.distance(points[index - 1], points[index]))
            }
            let segment = Segment(points: points, cumulative: cumulative, offset: total)
            segments.append(segment)
            total += segment.length
        }
        let start = runs[0][0]
        guard runs.reduce(0, { $0 + $1.count }) >= 3, total >= 50,
              runs.joined().contains(where: { BreadcrumbMath.distance(start, $0) >= 20 }) else {
            throw BuildError.insufficientTrail
        }
        return Self(id: UUID(), sourceRideStartedAt: sourceRideStartedAt, segments: segments, length: total)
    }
}

enum BacktrackLocationValidity: Equatable, Sendable {
    case waiting, usable, poorAccuracy, stale, jumpRejected, unavailable
}
struct BacktrackProgress: Equatable, Sendable {
    var segmentIndex = 0
    var segmentDistance = 0.0
    var remainingDistance = 0.0
    var target: WGS84Point?
    var distanceToTarget: Double?
    var targetBearing: Double?
    var relativeDirection: Double?
    var currentPosition: WGS84Point?
    var offTrack = false
    var trailGap = false
    var arrived = false
    var locationValidity: BacktrackLocationValidity = .waiting
}
struct BacktrackComponentState: Equatable, Sendable {
    let routeIdentity: UUID
    let offTrack: Bool
    let arrived: Bool
    let paused: Bool
    let locationValidity: BacktrackLocationValidity
    let urgentEventIdentity: String?
}

/// AppModel owns this value. Route is fixed; only local guidance progresses.
struct BacktrackSession: Equatable, Sendable {
    let route: BacktrackRoute
    private(set) var progress: BacktrackProgress
    private var lastGoodFix: NavigationFix?
    private var lastObservationTime: Date?
    private var offTrackEvent = 0

    init(route: BacktrackRoute) {
        self.route = route
        progress = BacktrackProgress(remainingDistance: route.length)
    }
    func component(paused: Bool) -> BacktrackComponentState {
        .init(routeIdentity: route.id, offTrack: progress.offTrack, arrived: progress.arrived,
              paused: paused, locationValidity: progress.locationValidity,
              urgentEventIdentity: progress.offTrack && offTrackEvent > 0 ? "\(route.id)-off-\(offTrackEvent)" : nil)
    }
    mutating func invalidate(_ validity: BacktrackLocationValidity) {
        progress.locationValidity = validity
        progress.distanceToTarget = nil
        progress.targetBearing = nil
        progress.relativeDirection = nil
    }
    mutating func refresh(at now: Date) {
        if let lastObservationTime, now.timeIntervalSince(lastObservationTime) > 15 {
            invalidate(.stale)
        }
    }
    mutating func update(_ fix: NavigationFix, at now: Date) {
        guard BreadcrumbMath.valid(fix.coordinate), fix.horizontalAccuracyM.isFinite,
              fix.horizontalAccuracyM >= 0, fix.timestamp.timeIntervalSince1970.isFinite,
              (0...15).contains(now.timeIntervalSince(fix.timestamp)) else {
            invalidate(.stale); return
        }
        guard lastObservationTime.map({ fix.timestamp > $0 }) ?? true else { return }
        lastObservationTime = fix.timestamp
        progress.currentPosition = fix.coordinate
        guard fix.horizontalAccuracyM <= 50 else { invalidate(.poorAccuracy); return }
        let displacement = lastGoodFix.map { BreadcrumbMath.distance($0.coordinate, fix.coordinate) } ?? 0
        if let lastGoodFix {
            let dt = min(15, fix.timestamp.timeIntervalSince(lastGoodFix.timestamp))
            let speed = fix.speedMps.flatMap { $0.isFinite && (0...60).contains($0) ? $0 : nil } ?? 0
            if displacement > max(60, speed * dt * 2 + lastGoodFix.horizontalAccuracyM + fix.horizontalAccuracyM) {
                invalidate(.jumpRejected); return
            }
        }
        lastGoodFix = fix
        progress.locationValidity = fix.horizontalAccuracyM <= 20 ? .usable : .poorAccuracy
        guard !progress.arrived else { return }
        var segment = route.segments[progress.segmentIndex]
        if progress.trailGap {
            // Only the next actual endpoint can close a gap; never project onto an invented edge.
            let next = route.segments[progress.segmentIndex + 1]
            if fix.horizontalAccuracyM <= 20, BreadcrumbMath.distance(fix.coordinate, next.points[0]) <= 15 {
                progress.segmentIndex += 1
                progress.segmentDistance = 0
                progress.trailGap = false
                segment = next
            } else {
                setOffTrack(false)
                setTarget(next.points[0], fix: fix)
                return
            }
        }
        let currentEdge = segment.edge(at: progress.segmentDistance)
        let lowerEdge = max(0, currentEdge - 4)
        // ponytail: bounded sequential matching deliberately refuses distant reacquisition.
        // A rider must rejoin the nearby eligible trail; no global nearest/HMM shortcuts.
        let advance = min(60, max(8, displacement * 1.5 + 3))
        let upperDistance = min(segment.length, progress.segmentDistance + advance)
        let upperEdge = min(segment.points.count - 2, min(currentEdge + 48, segment.edge(at: upperDistance)))
        var bestDistance = Double.infinity
        var bestAlong = progress.segmentDistance
        var bestPoint = segment.point(at: progress.segmentDistance)
        var behindDistance = Double.infinity
        var behindPoint = bestPoint
        if segment.points.count > 1 {
            for index in lowerEdge...max(lowerEdge, upperEdge) {
                let projection = BreadcrumbMath.projection(fix.coordinate, segment.points[index], segment.points[index + 1])
                let edgeLength = segment.cumulative[index + 1] - segment.cumulative[index]
                let lower = max(segment.cumulative[index], progress.segmentDistance - 20)
                let upper = min(segment.cumulative[index + 1], upperDistance)
                guard lower <= upper else { continue }
                // Clip the projection to the eligible part of this real edge.
                // A sparse edge can extend beyond the window without disappearing.
                let along = min(upper, max(lower, segment.cumulative[index] + projection.fraction * edgeLength))
                let point = BreadcrumbMath.interpolate(segment.points[index], segment.points[index + 1],
                    fraction: edgeLength > 0 ? (along - segment.cumulative[index]) / edgeLength : 0)
                let distance = BreadcrumbMath.distance(fix.coordinate, point)
                if along < progress.segmentDistance {
                    if distance < behindDistance {
                        behindDistance = distance
                        behindPoint = point
                    }
                    continue
                }
                // Ties favor the earliest eligible location at a crossing/overlap.
                if distance < bestDistance - 2 {
                    bestDistance = distance; bestAlong = along; bestPoint = point
                }
            }
        }
        // The retained position is always an eligible rejoin target, even if every
        // unconstrained edge projection lies outside the forward search window.
        let retained = segment.point(at: progress.segmentDistance)
        let retainedDistance = BreadcrumbMath.distance(fix.coordinate, retained)
        if retainedDistance < bestDistance {
            bestDistance = retainedDistance; bestAlong = progress.segmentDistance; bestPoint = retained
        }
        // Overlapping outward/return legs need an equally close forward edge to
        // win over a point behind progress. Otherwise a U-turn can stall forever.
        if behindDistance < bestDistance - 2 {
            bestDistance = behindDistance; bestAlong = progress.segmentDistance; bestPoint = behindPoint
        }
        let threshold = max(25, fix.horizontalAccuracyM * 2)
        let offTrack = bestDistance > (progress.offTrack ? threshold * 0.7 : threshold)
        setOffTrack(offTrack)
        // Ambiguous accuracy cannot move progress, switch a gap or arrive.
        if !offTrack, fix.horizontalAccuracyM <= 20, bestDistance <= 20,
           bestAlong > progress.segmentDistance + 3 {
            progress.segmentDistance = bestAlong
        }
        progress.remainingDistance = max(0, route.length - segment.offset - progress.segmentDistance)
        if progress.segmentIndex == route.segments.count - 1,
           segment.length - progress.segmentDistance <= 10,
           fix.horizontalAccuracyM <= 20,
           BreadcrumbMath.distance(fix.coordinate, route.rideStart) <= max(10, min(15, fix.horizontalAccuracyM)) {
            progress.arrived = true
            progress.segmentDistance = segment.length
            progress.remainingDistance = 0
            setOffTrack(false)
            setTarget(route.rideStart, fix: fix)
            return
        }
        if !offTrack, fix.horizontalAccuracyM <= 20,
           segment.length - progress.segmentDistance <= 5,
           BreadcrumbMath.distance(fix.coordinate, segment.points.last!) <= 15,
           progress.segmentIndex + 1 < route.segments.count {
            progress.segmentDistance = segment.length
            progress.remainingDistance = max(0, route.length - segment.offset - segment.length)
            progress.trailGap = true
            setTarget(route.segments[progress.segmentIndex + 1].points[0], fix: fix)
        } else {
            setTarget(offTrack ? bestPoint : segment.point(at: min(segment.length, progress.segmentDistance + 30)), fix: fix)
        }
    }
    private mutating func setOffTrack(_ value: Bool) {
        if value && !progress.offTrack { offTrackEvent += 1 }
        progress.offTrack = value
    }
    private mutating func setTarget(_ point: WGS84Point, fix: NavigationFix) {
        progress.target = point
        progress.distanceToTarget = BreadcrumbMath.distance(fix.coordinate, point)
        progress.targetBearing = BreadcrumbMath.bearing(fix.coordinate, point)
        let usableCourse = fix.courseDeg.flatMap { $0.isFinite && (0..<360).contains($0) ? $0 : nil }
        if let course = usableCourse, let speed = fix.speedMps, speed.isFinite, (2...60).contains(speed),
           fix.horizontalAccuracyM <= 20, let bearing = progress.targetBearing {
            progress.relativeDirection = BreadcrumbMath.wrapped(bearing - course)
        } else { progress.relativeDirection = nil }
    }
}
