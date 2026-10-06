import Foundation
import MotoNavigationCore

/// One continuous platform source, two consumers. Navigation's stop releases
/// only its subscription; Ride can keep receiving observations without NavCore.
@MainActor
final class SharedLocationSource: NavigationLocationSource {
    private let source: any NavigationLocationSource
    private var navigationFix: (@MainActor (NavigationFix) -> Void)?
    private var navigationFailure: (@MainActor (String) -> Void)?
    private var rideFix: (@MainActor (NavigationFix) -> Void)?
    private var rideFailure: (@MainActor (String) -> Void)?
    private var running = false

    init(source: any NavigationLocationSource) { self.source = source }

    func start(onFix: @escaping @MainActor (NavigationFix) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) throws {
        navigationFix = onFix
        navigationFailure = onFailure
        do { try ensureRunning() } catch {
            navigationFix = nil
            navigationFailure = nil
            throw error
        }
    }

    func stop() {
        navigationFix = nil
        navigationFailure = nil
        stopIfUnused()
    }

    func startRide(onFix: @escaping @MainActor (NavigationFix) -> Void,
                   onFailure: @escaping @MainActor (String) -> Void) throws {
        rideFix = onFix
        rideFailure = onFailure
        do { try ensureRunning() } catch {
            rideFix = nil
            rideFailure = nil
            throw error
        }
    }

    func stopRide() {
        rideFix = nil
        rideFailure = nil
        stopIfUnused()
    }

    private func ensureRunning() throws {
        guard !running else { return }
        do {
            try source.start(onFix: { [weak self] fix in
                self?.navigationFix?(fix)
                self?.rideFix?(fix)
            }, onFailure: { [weak self] message in
                self?.navigationFailure?(message)
                self?.rideFailure?(message)
            })
            running = true
        } catch {
            source.stop()
            throw error
        }
    }

    private func stopIfUnused() {
        guard running, navigationFix == nil, rideFix == nil else { return }
        source.stop()
        running = false
    }
}
