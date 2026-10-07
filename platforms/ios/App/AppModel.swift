import Combine
import Foundation
import MotoNavigationCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var navigation = MotoNavCoreBridge().snapshot
    @Published private(set) var device = BLEDeviceSnapshot()
    @Published private(set) var navigationFailure: String?
    @Published private(set) var isNavigationActive = false
    @Published private(set) var isDemoActive = false
    @Published private var rideSession = RideSession()

    @Published private(set) var backtrackSession: BacktrackSession?
    @Published private(set) var backtrackFailure: String?
    @Published private(set) var guidanceConflict: GuidanceConflict?
    enum GuidanceConflict { case startBacktrack, startNavigation }
    private var pendingGuidanceSwitch: (() -> Void)?
    private var latestRideFix: NavigationFix?
    private var backtrackFreshnessTask: Task<Void, Never>?
    // A read-only eligibility cache; computed from real recorded points until ready.
    @Published private(set) var backtrackTrailReady = false
    private var backtrackHasSpatialExtent = false
    var isBacktrackActive: Bool { backtrackSession != nil }
    var backtrackComponentState: BacktrackComponentState? {
        backtrackSession?.component(paused: rideSession.state == .paused)
    }
    var backtrackUnavailableReason: String? {
        if !rideActive { return "Start Ride to record a trail" }
        if rideSession.state == .paused { return "Resume Ride to start Backtrack" }
        if !backtrackTrailReady { return "Not enough ride history yet" }
        return nil
    }

    func startBacktrack() {
        guard !isBacktrackActive else { return }
        guard backtrackUnavailableReason == nil, let startedAt = rideSession.startedAt else {
            backtrackFailure = backtrackUnavailableReason
            return
        }
        // Validate the concrete source before asking to end another guidance mode.
        guard let route = try? BacktrackRoute.build(track: rideSession.track, sourceRideStartedAt: startedAt) else {
            backtrackFailure = "Not enough ride history yet"
            return
        }
        if isNavigationActive {
            guidanceConflict = .startBacktrack
            pendingGuidanceSwitch = { [weak self] in self?.startBacktrack() }
            return
        }
        backtrackFailure = nil
        backtrackSession = BacktrackSession(route: route)
        if let fix = latestRideFix { backtrackSession?.update(fix, at: rideNow()) }
        updatePresentation()
        backtrackFreshnessTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, !Task.isCancelled, self.isBacktrackActive else { return }
                self.backtrackSession?.refresh(at: self.rideNow())
                self.updatePresentation()
            }
        }
    }

    func endBacktrack() {
        backtrackFreshnessTask?.cancel()
        backtrackFreshnessTask = nil
        backtrackSession = nil
        backtrackFailure = nil
        updatePresentation()
    }

    func cancelGuidanceSwitch() {
        guidanceConflict = nil
        pendingGuidanceSwitch = nil
    }

    func confirmGuidanceSwitch() {
        guard let conflict = guidanceConflict, let action = pendingGuidanceSwitch else { return }
        cancelGuidanceSwitch()
        switch conflict {
        case .startBacktrack:
            guard backtrackUnavailableReason == nil else { return }
            stopNavigation()
        case .startNavigation: endBacktrack()
        }
        action()
    }

    private func confirmNavigationReplacement(_ action: @escaping () -> Void) -> Bool {
        guard isBacktrackActive else { return true }
        guidanceConflict = .startNavigation
        pendingGuidanceSwitch = action
        return false
    }

    var rideSessionState: RideSessionState { rideSession.state }
    var rideActive: Bool { rideSession.isActive }

    @Published private(set) var rideFailure: String?
    var rideRecord: RideRecord? { rideSession.record }
    @Published private(set) var lastRideRecord: RideRecord?
    @Published private(set) var rideHistory: [RideRecord] = []
    @Published private(set) var rideHistoryLoading = true
    @Published private(set) var rideHistoryError: String?
    @Published private(set) var rideSaveErrors: [UUID: String] = [:]
    @Published private(set) var savingRideIDs: Set<UUID> = []
    @Published var rideSummaryID: UUID?
    private let rideStore: RideStore
    private var ridePersistenceTask: Task<Void, Never>?
    private var latestStoppedRideID: UUID?
    // Transaction ownership only; RideSession remains the sole live Ride state.
    private var pendingAutomaticRide = false

    var presentationDecision: PresentationDecision {
        presentationDriver.currentDecision
    }
    var rideTrack: [RideTrackPoint] { rideSession.track }
    var rideDistance: Double { rideSession.distance }
    var rideMovingTime: TimeInterval { rideSession.movingTime }
    var rideMaxSpeed: Double? { rideSession.maxSpeed }
    var rideElapsedTime: TimeInterval { rideSession.elapsedTime(at: rideNow()) }
    var rideCurrentSpeed: Double? { rideSession.currentSpeed(at: rideNow()) }

    func startRide() {
        guard !rideSession.isActive else { return }
        guard subscribeRideLocation() else { return }
        rideSession.start(at: rideNow())
        latestRideFix = nil
        backtrackTrailReady = false
        backtrackHasSpatialExtent = false
        backtrackFailure = nil
        updatePresentation()
    }

    func pauseRide() {
        guard rideSession.state == .active else { return }
        rideSession.pause(at: rideNow())
        backtrackSession?.invalidate(.waiting)
        liveLocation.stopRide()
        updatePresentation()
    }

    func resumeRide() {
        guard rideSession.state == .paused, subscribeRideLocation() else { return }
        rideSession.resume(at: rideNow())
        backtrackSession?.invalidate(.waiting)
        updatePresentation()
    }

    func stopRide() {
        guard rideActive else { return }
        pendingAutomaticRide = false
        cancelGuidanceSwitch()
        endBacktrack()
        guard let record = rideSession.stop(at: rideNow()) else { return }
        liveLocation.stopRide()
        updatePresentation()
        // The session and queued operation retain the real snapshot during I/O.
        latestStoppedRideID = record.id
        savingRideIDs.insert(record.id)
        let mayPresentSummary = !isNavigationActive
        enqueueRidePersistence { [weak self] in
            guard let self else { return }
            do {
                self.rideHistory = try await self.rideStore.append(record)
                self.rideSaveErrors[record.id] = nil
            } catch {
                self.rideSaveErrors[record.id] = error.localizedDescription
            }
            self.savingRideIDs.remove(record.id)
            // Publish the completed result after the persistence attempt, including failure.
            if self.latestStoppedRideID == record.id { self.lastRideRecord = record }
            if mayPresentSummary, !self.isNavigationActive, !self.rideActive,
               self.lastRideRecord?.id == record.id {
                self.rideSummaryID = record.id
            }
        }
    }

    func savedRide(id: UUID) -> RideRecord? {
        rideHistory.first(where: { $0.id == id }) ?? (lastRideRecord?.id == id ? lastRideRecord : nil)
    }

    func renameRide(id: UUID, name: String) async throws {
        try await mutateRideHistory {
            let records = try await self.rideStore.updateName(id: id, name: name)
            self.rideHistory = records
            if self.lastRideRecord?.id == id { self.lastRideRecord = records.first(where: { $0.id == id }) }
        }
    }

    func deleteRide(id: UUID) async throws {
        try await mutateRideHistory {
            self.rideHistory = try await self.rideStore.delete(id: id)
            if self.lastRideRecord?.id == id { self.lastRideRecord = nil }
            self.rideSaveErrors[id] = nil
            if self.rideSummaryID == id { self.rideSummaryID = nil }
        }
    }

    func retryRideSave(id: UUID) {
        guard let record = savedRide(id: id), !savingRideIDs.contains(id) else { return }
        savingRideIDs.insert(id)
        enqueueRidePersistence { [weak self] in
            guard let self else { return }
            do {
                self.rideHistory = try await self.rideStore.append(record)
                self.rideSaveErrors[id] = nil
            } catch { self.rideSaveErrors[id] = error.localizedDescription }
            self.savingRideIDs.remove(id)
        }
    }

    func waitForRidePersistence() async { await ridePersistenceTask?.value }

    private func mutateRideHistory(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = ridePersistenceTask
        let mutation = Task {
            await previous?.value
            try await operation()
        }
        ridePersistenceTask = Task { _ = try? await mutation.value }
        try await mutation.value
    }

    private func enqueueRidePersistence(_ operation: @escaping @MainActor () async -> Void) {
        let previous = ridePersistenceTask
        ridePersistenceTask = Task {
            await previous?.value
            await operation()
        }
    }

    private func subscribeRideLocation() -> Bool {
        do {
            try liveLocation.startRide(onFix: { [weak self] fix in
                guard let self else { return }
                let count = self.rideSession.track.count
                self.rideSession.accept(fix, receivedAt: self.rideNow())
                self.latestRideFix = fix
                if !self.backtrackTrailReady, self.rideSession.track.count != count {
                    if let first = self.rideSession.track.first {
                        let start = WGS84Point(longitudeDeg: first.longitude, latitudeDeg: first.latitude)
                        for point in self.rideSession.track.suffix(self.rideSession.track.count - count) {
                            let position = WGS84Point(longitudeDeg: point.longitude, latitudeDeg: point.latitude)
                            if BreadcrumbMath.distance(start, position) >= 20 { self.backtrackHasSpatialExtent = true }
                        }
                    }
                    if self.backtrackHasSpatialExtent, self.rideSession.track.count >= 3, self.rideSession.distance >= 50 {
                        // Full route validation happens once at eligibility, then once at Start.
                        self.backtrackTrailReady = BacktrackRoute.isEligible(track: self.rideSession.track)
                    }
                }
                if self.rideSession.state == .active, self.isBacktrackActive {
                    self.backtrackSession?.update(fix, at: self.rideNow())
                    self.updatePresentation()
                }
            }, onFailure: { [weak self] message in
                self?.rideFailure = message
                self?.backtrackSession?.invalidate(.unavailable)
                self?.updatePresentation()
            })
            rideFailure = nil
            return true
        } catch {
            rideFailure = error.localizedDescription
            return false
        }
    }

    @Published var destinationQuery = ""
    @Published private(set) var placeResults: [PlaceSearchResult] = []
    @Published private(set) var selectedPlace: PlaceSearchResult?
    @Published private(set) var recentPlaces: [PlaceSearchResult] = []
    @Published private(set) var isSearchingPlaces = false
    @Published private(set) var placeSearchFailure: String?
    @Published private(set) var searchLocationStatus: SearchLocationBiasStatus = .preparing
    @Published private(set) var routePreviewCandidates: [RoutePreviewCandidate] = []
    @Published private(set) var selectedRoutePreviewID: String?
    @Published private(set) var routePreviewOrigin: WGS84Point?
    @Published private(set) var isPlanningRoutePreview = false
    @Published private(set) var routePreviewFailure: String?

    private let bluetooth = ESP32BLECentral()
    let presentationDriver: PresentationDriver
    private let liveLocation: SharedLocationSource
    private let rideNow: () -> Date
    private let searchLocation = SearchLocationBiasSource()
    private var liveRouteProvider: AmapGatewayRouteProvider
    private var placeProvider: AmapGatewayPlaceProvider
    private let mediaController = AppleMusicRemoteController()
    @Published private(set) var mediaState: PhoneMediaState?

    // Playback updates are facts; only an accepted user control opens a window.
    @discardableResult
    func performMediaCommand(_ kind: UInt8) -> BLECommandDisposition {
        let status = mediaController.handleDeviceCommand(kind: kind)
        if status == .accepted {
            // The BLE transport already rejects duplicate command IDs per session.
            presentationDriver.mediaInteracted(eventIdentity: UUID().uuidString)
        }
        return status
    }
    let surroundingMap: SurroundingMapStore
    @Published private(set) var mapGatewayBaseURL: URL
    @Published private(set) var isUpdatingGateway = false
    private var runtime: SharedNavigationRuntime?
    private var placeSearchTask: Task<Void, Never>?
    private var routePreviewTask: Task<Void, Never>?
    private var routePreviewRequestID: UInt32 = 1
    private var routePreviewGeneration: UInt64 = 0

    private static let recentPlacesKey = "Waymate.RecentPlaces.v1"
    private static let legacyRecentPlacesKey = "MotoGPS.RecentPlaces.v1"

    init(gatewayBaseURL: URL = AppConfiguration.gatewayBaseURL, startsServices: Bool = true,
         locationSource: (any NavigationLocationSource)? = nil,
         rideNow: @escaping () -> Date = Date.init,
         presentationDriver: PresentationDriver? = nil,
         rideStore: RideStore? = nil) {
        let presentationDriver = presentationDriver ?? PresentationDriver()
        self.presentationDriver = presentationDriver
        liveLocation = SharedLocationSource(source: locationSource ?? CoreLocationNavigationSource())
        self.rideNow = rideNow
        // Service-free tests use isolated scratch storage, never user history.
        var rideFileURL = startsServices
            ? RideStore.defaultFileURL
            : FileManager.default.temporaryDirectory.appendingPathComponent("WaymateTests-\(UUID())/history.json")
        #if DEBUG
        // Isolate UI-test files without supplying any fake records or GPS data.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--waymate-ui-ride-store"), index + 1 < arguments.count,
           let testID = UUID(uuidString: arguments[index + 1]) {
            rideFileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("WaymateUITests-\(testID)/history.json")
        }
        #endif
        self.rideStore = rideStore ?? RideStore(fileURL: rideFileURL)
        liveRouteProvider = AmapGatewayRouteProvider(baseURL: gatewayBaseURL)
        placeProvider = AmapGatewayPlaceProvider(baseURL: gatewayBaseURL)
        mapGatewayBaseURL = gatewayBaseURL
        surroundingMap = SurroundingMapStore(baseURL: gatewayBaseURL)
        recentPlaces = Self.loadRecentPlaces()
        enqueueRidePersistence { [weak self] in
            guard let self else { return }
            do { self.rideHistory = try await self.rideStore.load() }
            catch { self.rideHistoryError = error.localizedDescription }
            self.rideHistoryLoading = false
        }

        surroundingMap.onScene = { [weak self] scene in
            self?.bluetooth.sendMapScene(scene)
        }

        bluetooth.onSnapshotChange = { [weak self] snapshot in
            self?.device = snapshot
        }
        bluetooth.onDeviceCommand = { [weak self] command in
            guard let self else { return .failed }
            switch command.kind {
            case 0:
                return self.presentationDriver.manuallySelect(rawValue: command.page)
                    ? .accepted
                    : .unsupported
            case 16 ... 19:
                return self.performMediaCommand(command.kind)
            default:
                return .unsupported
            }
        }
        mediaController.onStateChange = { [weak self] state in
            self?.mediaState = state
            self?.bluetooth.sendMediaState(state)
        }
        presentationDriver.onSelection = { [weak self] page in
            guard let self else { return }
            self.bluetooth.sendNavigationSnapshot(self.navigation, displayPage: page)
        }
        bluetooth.onDisplayResynchronization = { [weak self] in
            self?.presentationDriver.resynchronize()
        }
        updatePresentation()
        searchLocation.onLocationChange = { [weak self] point in
            guard let self else { return }
            let query = self.destinationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if point != nil, self.selectedPlace == nil, query.count >= 2 {
                // A fresh one-shot fix may arrive after a nationwide request
                // has already started. Replace it with a location-biased search
                // without requesting location again and creating a callback loop.
                self.schedulePlaceSearch(query: query, delay: .zero)
            }
            if point != nil, self.selectedPlace != nil,
               self.isPlanningRoutePreview, self.routePreviewTask == nil
            {
                self.beginRoutePreviewRequestIfPossible()
            }
        }
        searchLocation.onStatusChange = { [weak self] status in
            guard let self else { return }
            self.searchLocationStatus = status
            guard self.isPlanningRoutePreview,
                  self.routePreviewTask == nil,
                  self.searchLocation.latestPoint == nil
            else { return }
            if status == .permissionDenied {
                self.failRoutePreview("需要当前位置才能规划路线，请在系统设置中允许定位")
            } else if status == .unavailable {
                self.failRoutePreview("暂时无法获取当前位置，请到开阔位置后重试")
            }
        }

        // Owner lifecycle tests can run without requesting permissions or services.
        guard startsServices else { return }

        #if DEBUG
        // Offline UI checks must not request device permissions or contact services.
        if ProcessInfo.processInfo.arguments.contains("--moto-ui-offline") { return }
        #endif
        searchLocation.prepare()
        mediaController.start()
        bluetooth.connect()

        #if DEBUG
        // Command-line-only hook for a repeatable phone-to-round-screen smoke
        // test. Normal App launches and the visible demo control are unchanged.
        if ProcessInfo.processInfo.arguments.contains("--moto-demo-on-launch") {
            Task { @MainActor [weak self] in
                self?.startDemoNavigation()
            }
        }
        #endif
    }

    deinit {
        placeSearchTask?.cancel()
        routePreviewTask?.cancel()
        backtrackFreshnessTask?.cancel()
    }

    var isGatewayConfigured: Bool {
        (try? GatewayConfiguration.normalizedURL(mapGatewayBaseURL.absoluteString)) != nil
    }

    func saveGatewayAddress(_ address: String) async throws {
        guard !isNavigationActive, !isUpdatingGateway else {
            throw GatewaySettingsError.navigationActive
        }
        let url = try GatewayConfiguration.normalizedURL(address)
        isUpdatingGateway = true
        defer { isUpdatingGateway = false }
        clearDestination()
        await surroundingMap.changeGateway(to: url)
        liveRouteProvider = AmapGatewayRouteProvider(baseURL: url)
        placeProvider = AmapGatewayPlaceProvider(baseURL: url)
        mapGatewayBaseURL = url
        try GatewayConfiguration.save(url.absoluteString)
    }

    var deviceReady: Bool {
        if case .connected = device.connection {
            return device.negotiatedProtocol == "V1"
        }
        return false
    }

    /// Navigation can start before BLE is ready. The central retains the newest
    /// snapshot and synchronizes it when the round display reconnects.
    var canStartNavigation: Bool {
        selectedPlace != nil && selectedRoutePreview != nil && !isPlanningRoutePreview
    }

    var selectedRoutePreview: RoutePreviewCandidate? {
        guard let selectedRoutePreviewID else { return nil }
        return routePreviewCandidates.first { $0.id == selectedRoutePreviewID }
    }

    var mapDownloadRoute: [GCJ02Point] {
        if isNavigationActive { return runtime?.activeRoutePolyline ?? [] }
        return selectedRoutePreview?.route.polyline ?? []
    }

    var hasRoutePreview: Bool {
        !routePreviewCandidates.isEmpty
    }

    var searchBiasAvailable: Bool {
        searchLocationStatus == .available
    }

    var phaseTitle: String {
        if navigationFailure != nil { return "导航需要处理" }
        switch navigation.stateName {
        case "acquiring": return isDemoActive ? "演示即将开始" : "正在获取位置"
        case "planning": return "正在规划路线"
        case "navigating": return isDemoActive ? "正在演示导航" : "导航已发送到圆屏"
        case "rerouting": return "偏航，正在重新规划"
        case "arrived": return isDemoActive ? "演示完成" : "已经到达"
        default: return "准备出发"
        }
    }

    var phaseDetail: String {
        if let navigationFailure { return navigationFailure }
        if isDemoActive, navigation.stateName == "navigating" {
            return deviceReady
                ? "真实济南路网正在同步 · 道路 © OpenStreetMap contributors"
                : "真实济南路网运行中 · 道路 © OpenStreetMap contributors"
        }
        switch navigation.stateName {
        case "acquiring": return "请保持精确定位开启"
        case "planning": return "正在读取高德实时路线与路况"
        case "navigating": return deviceReady ? "手机可以锁屏并放入口袋" : "手机继续导航，圆屏连接后自动同步"
        case "rerouting": return "新路线生成后会自动同步到圆屏"
        case "arrived": return "本次导航已经完成"
        default: return "选择终点后，路线会通过蓝牙发送到圆屏"
        }
    }

    var navigationComponentState: NavigationComponentState {
        NavigationComponentState(snapshot: navigation)
    }

    var remainingDistanceText: String {
        guard let meters = navigationComponentState.remainingDistanceM else { return "—" }
        return formatDistance(meters)
    }

    var remainingDurationText: String {
        guard let seconds = navigationComponentState.remainingDurationS else { return "—" }
        return formatDuration(Int(seconds))
    }

    var primaryActionTitle: String {
        if isNavigationActive { return "结束导航" }
        if isPlanningRoutePreview { return "正在规划路线" }
        if selectedPlace == nil { return "请先选择终点" }
        if selectedRoutePreview == nil { return "重新规划路线" }
        return "开始导航"
    }

    var activeDestinationName: String {
        isDemoActive ? "WAYMATE 演示路线" : (selectedPlace?.name ?? "目的地")
    }

    var searchScopeText: String {
        switch searchLocationStatus {
        case .available:
            return "已按当前位置优先排序"
        case .preparing:
            return "正在获取当前位置；暂按全国搜索"
        case .permissionDenied:
            return "未获定位权限；暂按全国搜索"
        case .unavailable:
            return "当前位置暂不可用；暂按全国搜索"
        }
    }

    func destinationQueryDidChange() {
        guard !isNavigationActive, !isUpdatingGateway else { return }
        navigationFailure = nil
        let query = destinationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedPlace?.name == query {
            // Selecting a POI writes its canonical name back into the field.
            // That programmatic change must not immediately launch another
            // search and temporarily disable the Start Navigation action.
            placeSearchTask?.cancel()
            placeResults = []
            isSearchingPlaces = false
            return
        }
        if selectedPlace?.name != query {
            selectedPlace = nil
            clearRoutePreviewState()
        }
        schedulePlaceSearch(query: query, delay: .milliseconds(480))
    }

    func submitDestinationSearch() {
        guard !isNavigationActive, !isUpdatingGateway else { return }
        searchLocation.refresh()
        let query = destinationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        schedulePlaceSearch(query: query, delay: .zero)
    }

    func selectPlace(_ place: PlaceSearchResult) {
        guard !isUpdatingGateway else { return }
        placeSearchTask?.cancel()
        isSearchingPlaces = false
        placeSearchFailure = nil
        navigationFailure = nil
        selectedPlace = place
        destinationQuery = place.name
        placeResults = []
        remember(place)
        planRoutePreview()
    }

    func clearDestination() {
        guard !isNavigationActive else { return }
        placeSearchTask?.cancel()
        destinationQuery = ""
        selectedPlace = nil
        placeResults = []
        isSearchingPlaces = false
        placeSearchFailure = nil
        navigationFailure = nil
        clearRoutePreviewState()
    }

    func clearRecentPlaces() {
        recentPlaces = []
        UserDefaults.standard.removeObject(forKey: Self.recentPlacesKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyRecentPlacesKey)
    }

    func toggleNavigation() {
        if isNavigationActive {
            stopNavigation()
        } else if selectedRoutePreview == nil {
            planRoutePreview()
        } else {
            startNavigation()
        }
    }

    func startNavigation() {
        guard !isNavigationActive else { return }
        guard !isUpdatingGateway, isGatewayConfigured else {
            navigationFailure = "请先在网关设置中填写服务地址"
            return
        }
        guard let selectedPlace else {
            navigationFailure = "请先从搜索结果中选择终点"
            return
        }
        guard let selectedRoutePreview else {
            navigationFailure = "请先完成路线规划并选择一条路线"
            return
        }
        guard let routePreviewOrigin else {
            navigationFailure = "路线起点已失效，请重新规划路线"
            planRoutePreview()
            return
        }

        routePreviewTask?.cancel()
        routePreviewTask = nil
        beginLiveNavigation(
            destination: selectedPlace.location,
            destinationPOIID: selectedPlace.id.isEmpty ? nil : selectedPlace.id,
            routeProvider: PreviewSelectedRouteProvider(
                selectedRoute: selectedRoutePreview.route,
                selectedRouteOrigin: routePreviewOrigin,
                liveProvider: liveRouteProvider
            )
        )
    }

    /// Starts the accepted live navigation request after the UI's preview checks.
    /// Tests can supply a route provider without permissions or network requests.
    func beginLiveNavigation(destination: WGS84Point, destinationPOIID: String? = nil,
                             routeProvider: any NavigationRouteProviding) {
        guard !isNavigationActive, !isUpdatingGateway else { return }
        guard confirmNavigationReplacement({ [weak self] in
            self?.beginLiveNavigation(destination: destination, destinationPOIID: destinationPOIID, routeProvider: routeProvider)
        }) else { return }
        if !rideActive {
            startRide()
            guard rideActive else {
                navigationFailure = rideFailure
                return
            }
            pendingAutomaticRide = true
        }
        surroundingMap.reset()
        runtime?.stop()
        let runtime = SharedNavigationRuntime(locationSource: liveLocation, routeProvider: routeProvider)
        bind(runtime)
        self.runtime = runtime
        isDemoActive = false
        navigationFailure = nil
        let started = runtime.start(destination: destination, destinationPOIID: destinationPOIID)
        isNavigationActive = started
        if !started {
            rollbackAutomaticRide()
            self.runtime = nil
        }
    }

    func startDemoNavigation() {
        guard !isNavigationActive, !isUpdatingGateway else { return }
        guard confirmNavigationReplacement({ [weak self] in self?.startDemoNavigation() }) else { return }
        surroundingMap.reset()
        runtime?.stop()
        let demoSession = DemoNavigationSession()
        let runtime = SharedNavigationRuntime(
            locationSource: DemoNavigationLocationSource(session: demoSession),
            routeProvider: DemoNavigationRouteProvider(
                liveProvider: liveRouteProvider,
                session: demoSession
            )
        )
        bind(runtime)
        self.runtime = runtime
        navigationFailure = nil
        isDemoActive = true
        let started = runtime.start(
            destination: JinanDemoFixture.requestedDestinationWGS84,
            destinationPOIID: JinanDemoFixture.destinationPOIID
        )
        isNavigationActive = started
        if !started {
            isDemoActive = false
            self.runtime = nil
        }
    }

    func stopNavigation() {
        // An explicit End Nav keeps even an acquiring Ride running.
        pendingAutomaticRide = false
        runtime?.stop()
        runtime = nil
        isNavigationActive = false
        isDemoActive = false
        navigationFailure = nil
        surroundingMap.reset()
        // Ending navigation used to leave selectedPlace set, so the app stuck
        // on route preview with no obvious way back to the home/search screen.
        // Match the web shell: end → back to destination search.
        clearDestination()
    }

    func selectRoutePreview(_ id: String) {
        guard routePreviewCandidates.contains(where: { $0.id == id }) else { return }
        selectedRoutePreviewID = id
        navigationFailure = nil
    }

    func planRoutePreview() {
        guard !isNavigationActive, !isUpdatingGateway, selectedPlace != nil else { return }
        guard isGatewayConfigured else {
            failRoutePreview("请先在网关设置中填写服务地址")
            return
        }
        routePreviewGeneration &+= 1
        routePreviewTask?.cancel()
        routePreviewTask = nil
        routePreviewCandidates = []
        selectedRoutePreviewID = nil
        routePreviewOrigin = nil
        routePreviewFailure = nil
        navigationFailure = nil
        isPlanningRoutePreview = true

        if searchLocationStatus == .permissionDenied {
            failRoutePreview("需要当前位置才能规划路线，请在系统设置中允许定位")
            return
        }
        if searchLocation.refreshForRoutePlanning() {
            // Always wait for this new one-shot fix. Reusing the location that
            // biased an earlier POI search can build a route from home after
            // the rider has already moved elsewhere.
            return
        }
        beginRoutePreviewRequestIfPossible()
    }

    func toggleDeviceConnection() {
        bluetooth.toggleConnection()
    }

    private func bind(_ runtime: SharedNavigationRuntime) {
        runtime.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            self.navigation = snapshot
            if snapshot.stateName == "navigating" || snapshot.stateName == "arrived" {
                self.navigationFailure = nil
                self.pendingAutomaticRide = false
            }
            if !self.updatePresentation() {
                self.bluetooth.sendNavigationSnapshot(snapshot, displayPage: self.presentationDriver.selectedPage)
            }
            if snapshot.hasRouteView {
                self.surroundingMap.update(
                    latitudeDeg: snapshot.routeViewOriginLatitudeDeg,
                    longitudeDeg: snapshot.routeViewOriginLongitudeDeg
                )
            }
        }
        runtime.onFailure = { [weak self] message in
            guard let self else { return }
            self.navigationFailure = message
            if self.pendingAutomaticRide {
                self.rollbackAutomaticRide()
                self.runtime?.stop()
                self.runtime = nil
                self.isNavigationActive = false
                self.surroundingMap.reset()
            }
        }
    }

    private func rollbackAutomaticRide() {
        guard pendingAutomaticRide else { return }
        pendingAutomaticRide = false
        liveLocation.stopRide()
        // A failed automatic start is discarded, never published as a completed Ride.
        rideSession = RideSession()
        updatePresentation()
    }

    @discardableResult
    private func updatePresentation() -> Bool {
        presentationDriver.update(navigation: navigationComponentState, rideActive: rideActive, backtrack: backtrackComponentState)
    }

    private func beginRoutePreviewRequestIfPossible() {
        guard routePreviewTask == nil,
              isPlanningRoutePreview,
              let place = selectedPlace,
              let origin = searchLocation.latestPoint
        else { return }

        let placeIdentity = Self.placeIdentity(place)
        routePreviewRequestID &+= 1
        if routePreviewRequestID == 0 { routePreviewRequestID = 1 }
        let request = RouteRequest(
            requestID: routePreviewRequestID,
            origin: origin,
            destination: place.location,
            destinationPOIID: place.id.isEmpty ? nil : place.id
        )
        let routeProvider = liveRouteProvider
        let generation = routePreviewGeneration
        routePreviewTask = Task { @MainActor [weak self, routeProvider] in
            defer {
                if self?.routePreviewGeneration == generation {
                    self?.routePreviewTask = nil
                }
            }
            do {
                let routes = try await routeProvider.routeOptions(for: request)
                try Task.checkCancellation()
                guard let self,
                      let currentPlace = self.selectedPlace,
                      Self.placeIdentity(currentPlace) == placeIdentity
                else { return }
                let candidates = routes.enumerated().map {
                    RoutePreviewCandidate(ordinal: $0.offset, route: $0.element)
                }
                guard let first = candidates.first else {
                    self.failRoutePreview("高德没有返回可用路线，请稍后重试")
                    return
                }
                self.routePreviewCandidates = candidates
                self.selectedRoutePreviewID = first.id
                self.routePreviewOrigin = origin
                self.routePreviewFailure = nil
                self.isPlanningRoutePreview = false
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.failRoutePreview("路线规划失败，请检查网络后重试")
            }
        }
    }

    private func failRoutePreview(_ message: String) {
        routePreviewTask?.cancel()
        routePreviewTask = nil
        routePreviewCandidates = []
        selectedRoutePreviewID = nil
        routePreviewOrigin = nil
        isPlanningRoutePreview = false
        routePreviewFailure = message
    }

    private func clearRoutePreviewState() {
        routePreviewGeneration &+= 1
        routePreviewTask?.cancel()
        routePreviewTask = nil
        routePreviewCandidates = []
        selectedRoutePreviewID = nil
        routePreviewOrigin = nil
        isPlanningRoutePreview = false
        routePreviewFailure = nil
    }

    private func schedulePlaceSearch(query: String, delay: Duration) {
        placeSearchTask?.cancel()
        placeSearchFailure = nil

        guard !isUpdatingGateway, isGatewayConfigured else {
            placeResults = []
            isSearchingPlaces = false
            if query.count >= 2 { placeSearchFailure = "请先在网关设置中填写服务地址" }
            return
        }
        guard query.count >= 2 else {
            placeResults = []
            isSearchingPlaces = false
            return
        }
        guard selectedPlace?.name != query else {
            placeResults = []
            isSearchingPlaces = false
            return
        }

        // Never leave a previous query tappable while the next request is in
        // flight; selecting stale rows can start navigation to the wrong POI.
        placeResults = []
        isSearchingPlaces = true
        placeSearchTask = Task { @MainActor [weak self] in
            do {
                if delay != .zero {
                    try await Task.sleep(for: delay)
                }
                guard let self else { return }
                let places = try await self.placeProvider.search(
                    keywords: query,
                    near: self.searchLocation.latestPoint
                )
                try Task.checkCancellation()
                guard self.destinationQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else {
                    return
                }
                self.placeResults = Self.deduplicated(places)
                self.isSearchingPlaces = false
                self.placeSearchFailure = self.placeResults.isEmpty
                    ? "没有找到，试试输入更完整的地点名"
                    : nil
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.placeResults = []
                self.isSearchingPlaces = false
                self.placeSearchFailure = "地点搜索失败，请检查网络后重试"
            }
        }
    }

    private func remember(_ place: PlaceSearchResult) {
        let key = Self.placeIdentity(place)
        recentPlaces.removeAll { Self.placeIdentity($0) == key }
        // Distance belongs to one location fix, not to the place itself. Keep
        // the exact destination but do not show a stale distance after the
        // rider moves or relaunches the app.
        recentPlaces.insert(
            PlaceSearchResult(
                id: place.id,
                name: place.name,
                address: place.address,
                city: place.city,
                district: place.district,
                displayArea: place.displayArea,
                location: place.location,
                distanceM: nil
            ),
            at: 0
        )
        if recentPlaces.count > 8 {
            recentPlaces.removeLast(recentPlaces.count - 8)
        }
        if let data = try? JSONEncoder().encode(recentPlaces) {
            UserDefaults.standard.set(data, forKey: Self.recentPlacesKey)
        }
    }

    private static func loadRecentPlaces() -> [PlaceSearchResult] {
        guard let places = WaymateDefaults.value(forKey: recentPlacesKey, legacyKey: legacyRecentPlacesKey, decode: {
            ($0 as? Data).flatMap { try? JSONDecoder().decode([PlaceSearchResult].self, from: $0) }
        }) else { return [] }
        return Array(deduplicated(places).prefix(8))
    }

    private static func deduplicated(_ places: [PlaceSearchResult]) -> [PlaceSearchResult] {
        var seen = Set<String>()
        return places.filter { seen.insert(placeIdentity($0)).inserted }
    }

    private static func placeIdentity(_ place: PlaceSearchResult) -> String {
        if !place.id.isEmpty { return "id:\(place.id)" }
        return "geo:\(place.name)|\(place.location.longitudeDeg)|\(place.location.latitudeDeg)"
    }

    private func formatDistance(_ meters: Double) -> String {
        guard meters.isFinite, meters > 0 else { return "--" }
        return meters >= 1_000
            ? String(format: "%.1f km", meters / 1_000)
            : "\(Int(meters.rounded())) m"
    }

    private func formatDuration(_ seconds: Int) -> String {
        guard seconds > 0 else { return "--" }
        let minutes = max(1, Int(round(Double(seconds) / 60)))
        return minutes >= 60 ? "\(minutes / 60)时\(minutes % 60)分" : "\(minutes)分钟"
    }
}

private enum GatewaySettingsError: LocalizedError {
    case navigationActive
    var errorDescription: String? { "请先结束导航，再更换网关地址。" }
}
