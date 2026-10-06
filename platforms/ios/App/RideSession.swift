import CoreLocation
import Foundation
import MotoNavigationCore

enum RideSessionState: Equatable, Sendable {
    case inactive, active, paused
}

/// WGS84 observations, never route-matched coordinates. Segment boundaries must
/// remain separate when a future map/export consumer draws the track.
struct RideTrackPoint: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let timestamp: Date
    let horizontalAccuracy: Double
    let speed: Double?
    let segment: Int
}

struct RideRecord: Equatable, Sendable {
    let startedAt: Date
    let endedAt: Date
    /// Active duration: explicit pauses excluded, stationary time included.
    let elapsedTime: TimeInterval
    let movingTime: TimeInterval
    let distance: Double
    let maxSpeed: Double?
    let track: [RideTrackPoint]

    var averageSpeed: Double? { movingTime > 0 ? distance / movingTime : nil }
}

/// AppModel owns this recorder. No navigation state or route geometry enters it.
/// All times are supplied by the owner (defaults only for convenience).
struct RideSession: Equatable, Sendable {
    private(set) var state: RideSessionState = .inactive
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?
    private(set) var movingTime: TimeInterval = 0
    private(set) var distance: Double = 0
    private(set) var maxSpeed: Double?
    private(set) var track: [RideTrackPoint] = []
    private(set) var record: RideRecord?
    private var activeSince: Date?
    private var accumulatedElapsed: TimeInterval = 0
    private var lastFix: NavigationFix?
    private var anchor: NavigationFix?
    private var needsNewSegment = true
    private var segment = 0

    // A paused ride still owns a session; repeated Start must not replace it.
    var isActive: Bool { state != .inactive }

    func elapsedTime(at now: Date) -> TimeInterval {
        accumulatedElapsed + (activeSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    func currentSpeed(at now: Date) -> Double? {
        guard state == .active, let fix = lastFix,
              (0...15).contains(now.timeIntervalSince(fix.timestamp)) else { return nil }
        return Self.speed(fix)
    }

    mutating func start(at now: Date = Date()) {
        guard state == .inactive else { return }
        self = RideSession()
        startedAt = now
        activeSince = now
        state = .active
    }

    mutating func pause(at now: Date = Date()) {
        guard state == .active else { return }
        flushEndpoint()
        accumulatedElapsed = elapsedTime(at: now)
        activeSince = nil
        state = .paused
        breakSegment()
    }

    mutating func resume(at now: Date = Date()) {
        guard state == .paused else { return }
        activeSince = now
        state = .active
        breakSegment()
    }

    @discardableResult
    mutating func stop(at now: Date = Date()) -> RideRecord? {
        guard state != .inactive, let startedAt else { return record }
        if state == .active { flushEndpoint() }
        accumulatedElapsed = elapsedTime(at: now)
        activeSince = nil
        let end = max(startedAt, now)
        endedAt = end
        state = .inactive
        breakSegment()
        record = RideRecord(startedAt: startedAt, endedAt: end,
                            elapsedTime: accumulatedElapsed, movingTime: movingTime,
                            distance: distance, maxSpeed: maxSpeed, track: track)
        return record
    }

    mutating func accept(_ fix: NavigationFix, receivedAt now: Date) {
        guard state == .active, let activeSince,
              fix.timestamp >= activeSince,
              CoreLocationNavigationSource.isUsable(fix, at: now),
              // Match NavCore's usable-accuracy ceiling; no route projection here.
              fix.horizontalAccuracyM <= 50,
              lastFix.map({ fix.timestamp > $0.timestamp }) ?? true else { return }

        if let previous = lastFix {
            let dt = fix.timestamp.timeIntervalSince(previous.timestamp)
            if dt > 15 {
                // Unknown travel across a GPS outage is not measured travel.
                flushEndpoint()
                breakSegment()
            } else {
                let separation = Self.distance(previous, fix)
                // Conservative observation envelope, not NavCore route matching.
                let observedSpeed = max(Self.speed(previous) ?? 0, Self.speed(fix) ?? 0)
                let allowance = max(10, observedSpeed * dt * 2)
                    + previous.horizontalAccuracyM + fix.horizontalAccuracyM
                guard separation <= allowance, separation / dt <= 100 else { return }
                // Count only intervals with motion confirmed at both endpoints.
                if let a = Self.speed(previous), let b = Self.speed(fix), a >= 0.5, b >= 0.5 {
                    movingTime += dt
                }
            }
        }
        if let speed = Self.speed(fix), speed < 0.5 { flushEndpoint() }
        lastFix = fix
        if let speed = Self.speed(fix) { maxSpeed = max(maxSpeed ?? 0, speed) }

        if let speed = Self.speed(fix), speed < 0.5 {
            // Parked GPS jitter must not accumulate distance or track points.
            anchor = nil
            needsNewSegment = true
            if track.isEmpty {
                append(fix)
                anchor = nil
                needsNewSegment = true
            }
            return
        }
        guard let anchor else {
            // Motion/stop oscillation must not bypass the sampling rate limit.
            if let last = track.last, fix.timestamp.timeIntervalSince(last.timestamp) < 2 { return }
            append(fix)
            return
        }
        let dt = fix.timestamp.timeIntervalSince(anchor.timestamp)
        let separation = Self.distance(anchor, fix)
        // Unknown speed needs displacement above the uncertainty floor.
        let minimumDistance = Self.speed(fix) == nil
            ? max(3, max(anchor.horizontalAccuracyM, fix.horizontalAccuracyM)) : 3
        // ponytail: at most 1 point / 2 seconds of sustained motion (~1800/hour).
        // Keep segment endpoints too; add compression only if real records demand it.
        if dt >= 2, separation >= minimumDistance { append(fix) }
    }

    private mutating func flushEndpoint() {
        guard let fix = lastFix, let anchor,
              fix.timestamp > anchor.timestamp,
              let speed = Self.speed(fix), speed >= 0.5,
              Self.distance(anchor, fix) >= 3 else { return }
        append(fix)
    }

    private mutating func append(_ fix: NavigationFix) {
        if needsNewSegment {
            if !track.isEmpty { segment += 1 }
            needsNewSegment = false
        } else if let anchor {
            distance += Self.distance(anchor, fix)
        }
        track.append(RideTrackPoint(latitude: fix.coordinate.latitudeDeg,
                                   longitude: fix.coordinate.longitudeDeg,
                                   timestamp: fix.timestamp,
                                   horizontalAccuracy: fix.horizontalAccuracyM,
                                   speed: Self.speed(fix), segment: segment))
        anchor = fix
    }

    private mutating func breakSegment() {
        lastFix = nil
        anchor = nil
        needsNewSegment = true
    }

    private static func speed(_ fix: NavigationFix) -> Double? {
        guard let speed = fix.speedMps, speed.isFinite, (0...100).contains(speed) else { return nil }
        return speed < 0.5 ? 0 : speed
    }

    private static func distance(_ a: NavigationFix, _ b: NavigationFix) -> Double {
        CLLocation(latitude: a.coordinate.latitudeDeg, longitude: a.coordinate.longitudeDeg)
            .distance(from: CLLocation(latitude: b.coordinate.latitudeDeg, longitude: b.coordinate.longitudeDeg))
    }
}
