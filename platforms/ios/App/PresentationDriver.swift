import Foundation

/// Existing BLE v1 pages. Ready is the Navigation renderer's idle mode.
enum RoundDisplayPage: UInt8, CaseIterable {
    case navigation = 0, speed = 1, compass = 2, music = 3, backtrack = 4

    var protocolName: String {
        switch self {
        case .navigation: return "navigation"
        case .speed: return "speed"
        case .compass: return "compass"
        case .music: return "music"
        case .backtrack: return "backtrack"
        }
    }

    init(primary: PresentationDecision.PrimaryComponent) {
        switch primary {
        case .idle, .navigation: self = .navigation
        case .ride: self = .speed
        case .backtrack: self = .backtrack
        case .media: self = .music
        }
    }
}

/// Event delivery around the pure Coordinator, not another priority policy.
/// selectedPage is the phone's synchronized selection; ESP32 applies swipes
/// immediately and reports them with the existing PageSelected command.
@MainActor
final class PresentationDriver {
    var onSelection: ((RoundDisplayPage) -> Void)?
    private(set) var selectedPage: RoundDisplayPage = .navigation
    private(set) var decision: PresentationDecision?
    private(set) var mediaInteraction: PresentationCoordinator.MediaInteraction?
    // Last read-only component input, never a second Ride lifecycle flag.
    private var facts = PresentationCoordinator.Input(
        navigation: nil, rideActive: false, mediaInteraction: nil
    )
    private var manualSelection = false
    private var mediaSuppressed = false
    private let now: () -> ContinuousClock.Instant
    private let schedulesExpiry: Bool
    private var expiryTask: Task<Void, Never>?

    var currentDecision: PresentationDecision { evaluate() }

    init(now: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now },
         schedulesExpiry: Bool = true) {
        self.now = now
        self.schedulesExpiry = schedulesExpiry
    }

    deinit { expiryTask?.cancel() }

    @discardableResult
    func update(navigation: NavigationComponentState?, rideActive: Bool,
                backtrack: BacktrackComponentState? = nil) -> Bool {
        // Read-only projections, refreshed by AppModel; no lifecycle ownership.
        facts = .init(navigation: navigation, rideActive: rideActive, mediaInteraction: nil, backtrack: backtrack)
        return reevaluate()
    }

    @discardableResult
    func manuallySelect(rawValue: UInt8) -> Bool {
        guard let page = RoundDisplayPage(rawValue: rawValue),
              page != .backtrack || facts.backtrack != nil else { return false }
        selectedPage = page
        manualSelection = true
        // A deliberate browse dismisses the automatic window. Keep its identity
        // for deduplication; a new interaction can open another window.
        mediaSuppressed = true
        expiryTask?.cancel()
        expiryTask = nil
        decision = evaluate()
        trace("manual page=\(page.protocolName)")
        onSelection?(page)
        return true
    }

    func mediaInteracted(eventIdentity: String) {
        guard mediaInteraction?.eventIdentity != eventIdentity else { return }
        mediaInteraction = .begin(eventIdentity: eventIdentity, at: now(), previous: mediaInteraction)
        // Controls on a deliberately selected Music page must not evict it.
        mediaSuppressed = manualSelection && selectedPage == .music
        expiryTask?.cancel()
        expiryTask = nil
        reevaluate()
        guard !mediaSuppressed, schedulesExpiry, let expiry = mediaInteraction?.expiry else { return }
        expiryTask = Task { @MainActor [weak self] in
            do { try await ContinuousClock().sleep(until: expiry) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.reevaluate()
        }
    }

    /// Called before BLE resends its baseline, never replays Media controls.
    func resynchronize() {
        reevaluate(force: true)
    }

    /// Also callable with injected time in tests, without sleeping.
    @discardableResult
    func reevaluate(force: Bool = false) -> Bool {
        let next = evaluate()
        let previous = decision
        decision = next
        let urgentEvent = (next.reason == .offRoute || next.reason == .rerouting)
            && next.reason != previous?.reason
        let backtrackEvent = next.reason == .backtrackOffTrack
            && next.urgentEventIdentity != previous?.urgentEventIdentity
        let backtrackArrival = next.reason == .backtrackArrived && previous?.reason != .backtrackArrived
        guard force || previous == nil
            || next.primaryComponent != previous?.primaryComponent
            || next.eventIdentity != previous?.eventIdentity
            || urgentEvent || backtrackEvent || backtrackArrival else { return false }
        selectedPage = RoundDisplayPage(primary: next.primaryComponent)
        manualSelection = false
        trace("\(String(describing: previous?.primaryComponent)) -> \(next.primaryComponent) reason=\(next.reason) event=\(next.eventIdentity ?? "--") resync=\(force)")
        onSelection?(selectedPage)
        return true
    }

    private func evaluate() -> PresentationDecision {
        PresentationCoordinator.evaluate(
            input: .init(navigation: facts.navigation, rideActive: facts.rideActive,
                         mediaInteraction: mediaSuppressed ? nil : mediaInteraction, backtrack: facts.backtrack),
            now: now()
        )
    }

    private func trace(_ message: String) {
        #if DEBUG
        print("[Presentation] \(message)")
        #endif
    }
}
