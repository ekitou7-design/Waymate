enum RideSessionState: Equatable, Sendable {
    case inactive
    case active
}

/// AppModel owns the session. Only explicit Ride commands change its state;
/// navigation, presentation and device connectivity do not control its lifetime.
struct RideSession: Equatable, Sendable {
    private(set) var state: RideSessionState = .inactive

    var isActive: Bool { state == .active }

    /// Idempotent: starting an active session leaves it active.
    mutating func start() {
        state = .active
    }

    /// Idempotent: stopping an inactive session leaves it inactive.
    mutating func stop() {
        state = .inactive
    }
}
