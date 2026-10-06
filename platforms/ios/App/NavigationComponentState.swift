/// A value projection of the authoritative NavCore snapshot, with no retained
/// bridge objects or navigation policy. Empty source strings are unavailable.
struct NavigationComponentState: Equatable, Sendable {
    struct Maneuver: Equatable, Sendable {
        let id: UInt32
        let typeName: String
        let roundaboutExit: UInt8
    }

    struct LocationValidity: Equatable, Sendable {
        let hasUsableFix: Bool
        let isStale: Bool
    }

    // Preserve the Bridge's phase names; this is not NavigationSession's phase.
    let phase: String
    let routeIdentity: String?
    let routeGeneration: UInt32
    let nextManeuver: Maneuver?
    let distanceToManeuverM: Double?
    /// The next maneuver's road, not an independently observed current road.
    let maneuverRoadName: String?
    let instruction: String?
    let remainingDistanceM: Double?
    let remainingDurationS: UInt32?
    let offRoute: Bool
    let locationValidity: LocationValidity

    var arrived: Bool { phase == "arrived" }

    /// An accepted route in a navigation/arrival phase. Location freshness and
    /// off-route status remain separate facts, not new Swift navigation rules.
    var isNavigationValid: Bool {
        routeIdentity != nil && ["navigating", "rerouting", "arrived"].contains(phase)
    }

    init(snapshot: MotoNavCoreSnapshot) {
        phase = snapshot.stateName
        routeIdentity = snapshot.routeID.isEmpty ? nil : snapshot.routeID
        routeGeneration = snapshot.routeGeneration
        let hasRoute = routeIdentity != nil
        let hasManeuver = hasRoute && snapshot.hasNextManeuver
        nextManeuver = hasManeuver ? Maneuver(
            id: snapshot.maneuverID,
            typeName: snapshot.maneuverTypeName,
            roundaboutExit: snapshot.roundaboutExit
        ) : nil
        distanceToManeuverM = hasManeuver ? snapshot.distanceToManeuverM : nil
        maneuverRoadName = hasManeuver && !snapshot.roadName.isEmpty ? snapshot.roadName : nil
        instruction = hasManeuver && !snapshot.instructionText.isEmpty ? snapshot.instructionText : nil
        // NavCore has no independent availability flags for route estimates.
        // Preserve its numbers (including zero) whenever an accepted route exists.
        remainingDistanceM = hasRoute ? snapshot.remainingDistanceM : nil
        remainingDurationS = hasRoute ? snapshot.remainingDurationS : nil
        offRoute = snapshot.offRoute
        locationValidity = LocationValidity(
            hasUsableFix: snapshot.hasUsableFix,
            isStale: snapshot.gnssStale
        )
    }
}
