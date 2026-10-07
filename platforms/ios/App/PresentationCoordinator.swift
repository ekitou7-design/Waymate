/// Pure presentation policy, consumed by the production PresentationDriver.
struct PresentationDecision: Equatable, Sendable {
    enum PrimaryComponent: Equatable, Sendable {
        case idle, ride, navigation, backtrack, media
    }

    enum Reason: Equatable, Sendable {
        case idle, rideHome, navigationHome, arrived, offRoute, rerouting, temporaryMedia
        case backtrackHome, backtrackOffTrack, backtrackArrived
    }

    let primaryComponent: PrimaryComponent
    let reason: Reason
    /// Identity of the temporary Media interaction, not a navigation event.
    let eventIdentity: String?
    let temporaryExpiry: ContinuousClock.Instant?
    var urgentEventIdentity: String? = nil
}

enum PresentationCoordinator {
    /// Create once per user interaction; retain the same value on subsequent ticks.
    /// A new interaction gets a new identity and start instant. Neither playback
    /// updates nor evaluate() create or renew an interaction.
    struct MediaInteraction: Equatable, Sendable {
        let eventIdentity: String
        let startedAt: ContinuousClock.Instant

        var expiry: ContinuousClock.Instant { startedAt.advanced(by: .seconds(5)) }

        /// Pure event deduplication. Keep the previous interaction even after
        /// expiry/preemption; only a new identity opens a new window.
        static func begin(
            eventIdentity: String,
            at now: ContinuousClock.Instant,
            previous: Self? = nil
        ) -> Self {
            if let previous, previous.eventIdentity == eventIdentity { return previous }
            return Self(eventIdentity: eventIdentity, startedAt: now)
        }

        private init(eventIdentity: String, startedAt: ContinuousClock.Instant) {
            self.eventIdentity = eventIdentity
            self.startedAt = startedAt
        }
    }

    struct Input: Equatable, Sendable {
        let navigation: NavigationComponentState?
        /// Read-only RideSession.isActive projection (AppModel.rideActive).
        /// This input is a fact for evaluation, never owned or changed here.
        let rideActive: Bool
        let mediaInteraction: MediaInteraction?
        var backtrack: BacktrackComponentState? = nil
    }

    /// All instants must use the same monotonic clock. Reads no clock itself and
    /// retains no previous page: expiry always re-evaluates current component facts.
    static func evaluate(input: Input, now: ContinuousClock.Instant) -> PresentationDecision {
        let navigation = input.navigation.flatMap { $0.isNavigationValid ? $0 : nil }
        if let navigation,
           !navigation.arrived,
           navigation.locationValidity.hasUsableFix,
           !navigation.locationValidity.isStale {
            if navigation.phase == "rerouting" {
                return decision(.navigation, .rerouting)
            }
            if navigation.offRoute {
                return decision(.navigation, .offRoute)
            }
            // No proximity heuristic: distance alone does not establish urgency.
        }

        if let backtrack = input.backtrack, !backtrack.paused, !backtrack.arrived,
           backtrack.locationValidity == .usable, backtrack.offTrack {
            var result = decision(.backtrack, .backtrackOffTrack)
            result.urgentEventIdentity = backtrack.urgentEventIdentity
            return result
        }

        if let media = input.mediaInteraction,
           now >= media.startedAt, now < media.expiry {
            return PresentationDecision(
                primaryComponent: .media,
                reason: .temporaryMedia,
                eventIdentity: media.eventIdentity,
                temporaryExpiry: media.expiry
            )
        }

        if let navigation {
            // Arrival remains a NavCore fact until its route/phase is cleared.
            // Unusable/stale location does not invalidate an accepted Home route
            // and does not by itself create an urgent presentation override.
            return decision(.navigation, navigation.arrived ? .arrived : .navigationHome)
        }
        if let backtrack = input.backtrack {
            return decision(.backtrack, backtrack.arrived ? .backtrackArrived : .backtrackHome)
        }
        return input.rideActive ? decision(.ride, .rideHome) : decision(.idle, .idle)
    }

    private static func decision(
        _ primary: PresentationDecision.PrimaryComponent,
        _ reason: PresentationDecision.Reason
    ) -> PresentationDecision {
        PresentationDecision(
            primaryComponent: primary, reason: reason,
            eventIdentity: nil, temporaryExpiry: nil
        )
    }
}
