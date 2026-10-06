import SwiftUI

enum MotoScreen: Hashable {
    case routePreview
    case activeNavigation
}

/// One primary flow: destination → route → ride. Device management is secondary.
struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @FocusState private var searchFocused: Bool
    @State private var showsDeviceDetails = false
    @State private var showsMapDownloads = false
    @State private var showsDataUse = false
    @State private var showsGatewaySettings = false
    @State private var showsMedia = false
    @State private var confirmsEndRide = false

    var body: some View {
        NavigationStack(path: navigationPath) {
            homeScreen
                .navigationDestination(for: MotoScreen.self) { screen in
                    switch screen {
                    case .routePreview: routePreviewScreen
                    case .activeNavigation: activeNavigationScreen
                    }
                }
        }
        .tint(WaymateTheme.accent)
        .onChange(of: model.destinationQuery) { _, _ in model.destinationQueryDidChange() }
        .onChange(of: model.selectedPlace) { _, place in
            if place != nil { searchFocused = false }
        }
        .onChange(of: model.isNavigationActive) { _, active in
            if active { searchFocused = false }
        }
        .sheet(isPresented: $showsDeviceDetails) { deviceDetails }
        .sheet(isPresented: $showsMapDownloads) {
            MapDownloadsView(
                store: model.surroundingMap,
                gatewayBaseURL: model.mapGatewayBaseURL,
                route: model.mapDownloadRoute,
                destinationName: model.selectedPlace?.name
            )
        }
        .sheet(isPresented: $showsMedia) { MediaView(model: model) }
        .confirmationDialog("结束当前 Ride？", isPresented: $confirmsEndRide, titleVisibility: .visible) {
            Button("结束 Ride", role: .destructive, action: model.stopRide)
                .accessibilityIdentifier("ride-end-confirm")
            Button("取消", role: .cancel) {}
        } message: {
            Text(model.isNavigationActive ? "保存本次记录。导航会继续运行。" : "保存本次记录并返回首页。")
        }
        .sheet(isPresented: $showsDataUse) { DataUseView() }
        .sheet(isPresented: $showsGatewaySettings) { GatewaySettingsView(model: model) }
    }

    // Derive the stack from the session instead of synchronizing two mutable
    // paths with onChange. A system Back gesture uses the same cleanup as End.
    private var navigationPath: Binding<[MotoScreen]> {
        Binding(
            get: {
                if model.isNavigationActive { return [.activeNavigation] }
                if model.selectedPlace != nil { return [.routePreview] }
                return []
            },
            set: { path in
                if model.isNavigationActive, !path.contains(.activeNavigation) {
                    model.stopNavigation()
                } else if model.selectedPlace != nil, !path.contains(.routePreview) {
                    model.clearDestination()
                }
            }
        )
    }

    // MARK: - Destination search

    private var homeScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    WaymateLogo(size: 28)
                    Text("waymate").font(.title2.weight(.semibold))
                    Spacer()
                }
                if model.rideActive {
                    rideSection
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(homeReadiness).font(.largeTitle.weight(.semibold))
                            .accessibilityIdentifier("home-readiness")
                        Text(homeReadinessDetail).font(.subheadline).foregroundStyle(.secondary)
                        if !dynamicTypeSize.isAccessibilitySize {
                            HStack(spacing: 10) {
                                Text("PHONE").font(.caption.weight(.medium))
                                Circle().fill(WaymateTheme.ice).frame(width: 6, height: 6).accessibilityHidden(true)
                                Capsule().fill(model.deviceReady ? WaymateTheme.ice : WaymateTheme.road)
                                    .frame(height: 3).accessibilityHidden(true)
                                Circle().fill(model.deviceReady ? WaymateTheme.ice : WaymateTheme.road)
                                    .frame(width: 6, height: 6).accessibilityHidden(true)
                                Text("DISPLAY").font(.caption.weight(.medium))
                            }
                        }
                        DeviceStatusView(device: model.device)
                    }
                    rideSection
                }
                VStack(alignment: .leading, spacing: 12) {
                    if model.rideActive {
                        Button("NAVIGATE · 去哪儿？") { searchFocused = true }
                            .font(.headline).frame(minHeight: 44)
                            .accessibilityLabel("搜索目的地，开始导航")
                            .accessibilityIdentifier("ride-navigate-button")
                    } else {
                        Text("去哪儿？").font(.title2.weight(.medium))
                    }
                    searchField.padding(.horizontal, 14).padding(.vertical, 6)
                        .background(WaymateTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    if model.searchLocationStatus == .permissionDenied {
                        Button("前往设置开启定位", action: openSystemSettings)
                    }
                }
                if !model.isGatewayConfigured {
                    Button { showsGatewaySettings = true } label: {
                        Label("设置导航网关", systemImage: "network")
                    }.accessibilityIdentifier("gateway-setup-button")
                    Text("填写网关地址后即可搜索地点和规划路线。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !model.destinationQuery.isEmpty {
                    searchResultsSection
                } else if !model.recentPlaces.isEmpty {
                    recentPlacesSection
                }
                Divider()
                VStack(alignment: .leading, spacing: 18) {
                    deviceSummaryButton
                    mapDownloadsButton
                    Button { showsMedia = true } label: { Label("Media · Apple Music", systemImage: "music.note").frame(minHeight: 44) }
                        .accessibilityIdentifier("media-open-button")
                    DisclosureGroup("更多") {
                        VStack(alignment: .leading, spacing: 18) {
                            demoButton
                            Button { showsGatewaySettings = true } label: { Label("网关设置", systemImage: "network") }
                                .accessibilityIdentifier("gateway-settings-button")
                            Button { showsDataUse = true } label: { Label("隐私与数据", systemImage: "hand.raised") }
                                .accessibilityIdentifier("privacy-data-button")
                        }.padding(.top, 14)
                    }
                }.font(.subheadline)
            }
            .padding(24)
        }
        .buttonStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
        .background(WaymateTheme.background)
        .environment(\.colorScheme, .dark)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(WaymateTheme.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showsGatewaySettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("网关设置")
                    .accessibilityIdentifier("gateway-settings-toolbar")
            }
            ToolbarItem(placement: .topBarTrailing) { deviceToolbarButton }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { searchFocused = false }
            }
        }
    }

    private var homeReadiness: String {
        if model.searchLocationStatus == .permissionDenied { return "LOCATION REQUIRED" }
        if !model.isGatewayConfigured { return "SETUP REQUIRED" }
        if !model.deviceReady { return "CONNECT DISPLAY" }
        if model.searchLocationStatus != .available { return "WAITING FOR GPS" }
        return "READY"
    }

    private var homeReadinessDetail: String {
        if model.searchLocationStatus == .permissionDenied { return "允许定位以记录 Ride 和规划路线。" }
        if !model.isGatewayConfigured { return "设置导航网关以搜索和规划路线；也可以直接开始 Ride。" }
        if !model.deviceReady { return "连接车把圆屏；也可以先在 iPhone 上开始 Ride。" }
        if model.searchLocationStatus != .available { return "圆屏已就绪，正在等待可用位置。" }
        return "选择目的地，或直接开始 Ride。"
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.secondary)
                .accessibilityHidden(true)
            TextField("搜索地点或地址", text: $model.destinationQuery)
                .font(.body)
                .accessibilityIdentifier("destination-search-field")
                .accessibilityLabel("搜索目的地")
                .focused($searchFocused)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit {
                    model.submitDestinationSearch()
                    searchFocused = false
                }
            if !model.destinationQuery.isEmpty {
                Button {
                    model.clearDestination()
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.secondary)
                        .frame(minWidth: 28, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("清空搜索")
            }
        }
        .frame(minHeight: 44)
    }

    private var searchResultsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("搜索结果").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if model.isSearchingPlaces {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("正在搜索…").foregroundStyle(Color.secondary)
                }
                .frame(minHeight: 56)
                .accessibilityElement(children: .combine)
            } else if !model.placeResults.isEmpty {
                ForEach(Array(model.placeResults.enumerated()), id: \.offset) { index, place in
                    Button { select(place) } label: {
                        placeRow(place, symbol: "mappin.circle.fill")
                    }
                    .accessibilityIdentifier("place-result-\(index)")
                }
            } else {
                ContentUnavailableView {
                    Label {
                        Text(model.placeSearchFailure == nil ? "输入地点名称" : "暂无结果")
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: { Image(systemName: "magnifyingglass") }
                } description: {
                    Text(model.placeSearchFailure ?? "至少输入两个字，例如“奥体中心”。")
                } actions: {
                    if model.placeSearchFailure != nil {
                        Button("重新搜索", action: model.submitDestinationSearch)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(model.searchScopeText)
                if model.searchLocationStatus == .permissionDenied {
                    Button("前往设置开启定位", action: openSystemSettings)
                }
            }
        }
    }

    private var recentPlacesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("最近搜索")
                Spacer()
                Button("清空", action: model.clearRecentPlaces)
                    .textCase(nil)
                    .accessibilityLabel("清空最近搜索")
            }.font(.caption).foregroundStyle(.secondary)
            ForEach(Array(model.recentPlaces.enumerated()), id: \.offset) { index, place in
                Button { select(place) } label: { placeRow(place, symbol: "clock") }
                    .accessibilityIdentifier("recent-place-\(index)")
            }
        }
    }

    private func placeRow(_ place: PlaceSearchResult, symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(symbol == "clock" ? Color.secondary : WaymateTheme.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(place.name)
                    .font(.body)
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(placeSubtitle(place))
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
                .accessibilityHidden(true)
        }
        .padding(.vertical, 7)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

    private func select(_ place: PlaceSearchResult) {
        searchFocused = false
        model.selectPlace(place)
    }

    private var demoButton: some View {
        Button {
            searchFocused = false
            model.startDemoNavigation()
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("演示导航").foregroundStyle(Color.primary)
                    Text("先体验一次导航流程")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                }
            } icon: {
                Image(systemName: "play.circle").foregroundStyle(WaymateTheme.accent)
            }
            .padding(.vertical, 5)
        }
        .accessibilityIdentifier("demo-navigation-button")
    }

    // MARK: - Route selection

    private var mapDownloadsButton: some View {
        Button { showsMapDownloads = true } label: {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("地图与离线下载").foregroundStyle(Color.primary)
                    Text("自动加载周边，也能提前保存城市和沿途地图")
                        .font(.subheadline).foregroundStyle(Color.secondary)
                }
            } icon: { Image(systemName: "map").foregroundStyle(WaymateTheme.accent) }
            .padding(.vertical, 5)
        }
        .accessibilityIdentifier("map-downloads-button")
    }

    private var routePreviewScreen: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let place = model.selectedPlace {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("ROUTE PREVIEW").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(place.name).font(.title2.weight(.semibold))
                            Text("从我的位置出发 · \(placeSubtitle(place))").font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.horizontal, 24)
                        if model.hasRoutePreview {
                            RouteOverviewMap(candidates: model.routePreviewCandidates,
                                             selectedID: model.selectedRoutePreviewID,
                                             origin: model.routePreviewOrigin, destination: place.location)
                                .frame(height: max(300, geometry.size.height * 0.52))
                                .accessibilityIdentifier("route-preview-map")
                                .accessibilityLabel("前往\(place.name)的路线全览")
                            VStack(alignment: .leading, spacing: 12) {
                                Text("选择路线").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                ForEach(model.routePreviewCandidates) { candidate in routeOptionRow(candidate) }
                                Text("高德驾车路线 · 预计时间会随路况变化").font(.caption).foregroundStyle(.secondary)
                                mapDownloadsButton
                            }.padding(.horizontal, 24)
                        } else if model.isPlanningRoutePreview {
                            HStack(spacing: 14) { ProgressView(); Text("正在规划路线 · 获取当前位置与路况…") }
                                .padding(24).accessibilityIdentifier("route-preview-loading")
                        } else if let failure = model.routePreviewFailure {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("无法规划路线").font(.title2)
                                failureMessage(failure)
                                if model.searchLocationStatus == .permissionDenied {
                                    Button("前往设置", action: openSystemSettings)
                                }
                            }.padding(24)
                        }
                        if let failure = model.navigationFailure { failureMessage(failure).padding(.horizontal, 24) }
                        if model.rideActive {
                            VStack(alignment: .leading, spacing: 12) { rideSection }
                                .padding(.horizontal, 24)
                        }
                    }
                }.padding(.vertical, 20)
            }
        }
        .buttonStyle(.plain)
        .background(WaymateTheme.background)
        .navigationTitle("路线")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("更换") { model.clearDestination(); searchFocused = true }
                    .accessibilityLabel("更换目的地")
                    .accessibilityIdentifier("destination-change-button")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { navigationActionBar }
        .environment(\.colorScheme, .dark)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(WaymateTheme.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func routeOptionRow(_ candidate: RoutePreviewCandidate) -> some View {
        let selected = candidate.id == model.selectedRoutePreviewID
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                model.selectRoutePreview(candidate.id)
            }
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(candidate.title)
                        .font(.subheadline)
                        .foregroundStyle(selected ? WaymateTheme.accent : .secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            routeDuration(candidate)
                            routeDistance(candidate)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            routeDuration(candidate)
                            routeDistance(candidate)
                        }
                    }
                    Label(candidate.trafficSummary, systemImage: "car.side")
                        .font(.subheadline)
                        .foregroundStyle(trafficTint(candidate))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? WaymateTheme.accent : Color(uiColor: .tertiaryLabel))
                    .accessibilityHidden(true)
            }
            .padding(16)
            .background(selected ? WaymateTheme.ice.opacity(0.08) : Color.clear)
            .overlay(alignment: .leading) {
                if selected { Capsule().fill(WaymateTheme.ice).frame(width: 3).padding(.vertical, 10) }
            }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("route-option-\(candidate.ordinal)")
        .accessibilityLabel("\(candidate.title)，\(candidate.durationText)，\(candidate.distanceText)，\(candidate.trafficSummary)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func routeDuration(_ candidate: RoutePreviewCandidate) -> some View {
        Text(candidate.durationText)
            .font(.title2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(Color.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func routeDistance(_ candidate: RoutePreviewCandidate) -> some View {
        Text(candidate.distanceText)
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(Color.secondary)
    }

    // MARK: - Ride in progress

    private var activeNavigationScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ActiveNavigationView(state: model.navigationComponentState, failure: model.navigationFailure,
                                     destination: model.activeDestinationName, duration: remainingDuration,
                                     distance: remainingDistance, rideActive: model.rideActive,
                                     ridePaused: model.rideSessionState == .paused, demo: model.isDemoActive)
                deviceSummaryButton
                VStack(alignment: .leading, spacing: 10) {
                    statusRow("手机定位", symbol: "location", value: locationStatus,
                              color: model.navigation.hasUsableFix && !model.navigationComponentState.locationValidity.isStale ? WaymateTheme.connected : WaymateTheme.warning)
                    statusRow("路况", symbol: "car.side", value: trafficStatus, color: .secondary)
                    SurroundingMapStatusRow(store: model.surroundingMap)
                    mapDownloadsButton
                    Button { showsMedia = true } label: { Label("Media · Apple Music", systemImage: "music.note").frame(minHeight: 44) }
                        .accessibilityIdentifier("media-open-button")
                }.font(.subheadline)
                Divider()
                rideSection
                if model.isDemoActive {
                    Text("道路数据 © OpenStreetMap contributors").font(.footnote).foregroundStyle(.secondary)
                }
            }.padding(24)
        }
        .buttonStyle(.plain)
        .background(WaymateTheme.background)
        .navigationTitle(model.isDemoActive ? "演示导航" : "导航中")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { deviceToolbarButton } }
        .safeAreaInset(edge: .bottom, spacing: 0) { navigationActionBar }
        .environment(\.colorScheme, .dark)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(WaymateTheme.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private var rideSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.rideActive {
                let paused = model.rideSessionState == .paused
                Text(paused ? "RIDE PAUSED" : "RIDE")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(paused ? WaymateTheme.warning : WaymateTheme.accent)
                Text(paused ? "Ride 已暂停" : "Ride 正在进行")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("ride-status")
                RideMetricsView(model: model, compact: model.selectedPlace != nil || model.isNavigationActive)
                if !model.isNavigationActive && model.selectedPlace == nil {
                    DeviceStatusView(device: model.device)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) { rideControls }
                    VStack(alignment: .leading, spacing: 18) { rideControls }
                }
            } else {
                Button("START RIDE", action: model.startRide)
                    .buttonStyle(WaymatePrimaryButtonStyle())
                    .accessibilityLabel("开始记录 Ride")
                    .accessibilityIdentifier("ride-start-button")
                if model.lastRideRecord != nil {
                    Text("最近一次 Ride 已结束").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("ride-record-ready")
                }
            }
            if let failure = model.rideFailure {
                failureMessage(failure).accessibilityIdentifier("ride-error")
                Button("检查定位权限", action: openSystemSettings)
            }
        }
    }

    @ViewBuilder private var rideControls: some View {
        if model.rideSessionState == .active {
            Button("PAUSE", action: model.pauseRide)
                .font(.headline).frame(minHeight: 44)
                .accessibilityLabel("暂停 Ride 记录")
                .accessibilityIdentifier("ride-pause-button")
        } else {
            Button("RESUME", action: model.resumeRide)
                .font(.headline).frame(minHeight: 44)
                .accessibilityLabel("继续 Ride 记录")
                .accessibilityIdentifier("ride-resume-button")
        }
        Button("END RIDE", role: .destructive) { confirmsEndRide = true }
            .font(.headline).frame(minHeight: 44)
            .foregroundStyle(WaymateTheme.error)
            .accessibilityLabel("结束 Ride，确认后保存记录")
            .accessibilityIdentifier("ride-end-button")
    }

    private var navigationActionBar: some View {
        VStack(spacing: 10) {
            Button(action: model.toggleNavigation) {
                HStack(spacing: 9) {
                    if model.isPlanningRoutePreview {
                        ProgressView().tint(model.isNavigationActive ? WaymateTheme.onError : WaymateTheme.onAccent)
                    } else {
                        Image(systemName: model.isNavigationActive ? "stop.fill" : "location.fill")
                    }
                    Text(model.isNavigationActive ? "END NAV" : (model.canStartNavigation ? "START NAV" : model.primaryActionTitle)).fixedSize(horizontal: false, vertical: true)
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 34)
                .padding(.vertical, 4)
            }
            .buttonStyle(WaymatePrimaryButtonStyle(destructive: model.isNavigationActive))
            .disabled(!model.isNavigationActive && (model.selectedPlace == nil || model.isPlanningRoutePreview))
            .accessibilityLabel(model.primaryActionTitle)
            .accessibilityIdentifier("primary-navigation-action")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(WaymateTheme.background)
    }

    // MARK: - Device sheet

    private var deviceToolbarButton: some View {
        Button {
            searchFocused = false
            showsDeviceDetails = true
        } label: { Image(systemName: "circle.circle").foregroundStyle(WaymateTheme.ice) }
        .accessibilityLabel("我的圆屏")
        .accessibilityValue(deviceStatus)
        .accessibilityIdentifier("device-details-button")
    }

    private var deviceSummaryButton: some View {
        Button {
            searchFocused = false
            showsDeviceDetails = true
        } label: {
            DeviceStatusView(device: model.device)
                .padding(.vertical, 6).contentShape(Rectangle())
        }
        .accessibilityIdentifier("device-summary-button")
    }

    private var deviceDetails: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "location.north.circle")
                            .font(.system(size: 64, weight: .ultraLight))
                            .foregroundStyle(WaymateTheme.accent)
                            .accessibilityHidden(true)
                        Text(deviceName).font(.title2.weight(.semibold))
                        Text(deviceDetail)
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .listRowBackground(Color.clear)
                Section {
                    statusRow("连接状态", symbol: "antenna.radiowaves.left.and.right", value: deviceStatus,
                              color: model.deviceReady ? WaymateTheme.connected : .secondary)
                    Button(connectionActionTitle, action: model.toggleDeviceConnection)
                        .accessibilityIdentifier("device-connection-action")
                    if case .bluetoothUnavailable = model.device.connection {
                        Button("打开系统设置", action: openSystemSettings)
                    }
                } footer: {
                    Text("圆屏保持开机并靠近 iPhone。连接成功后，当前导航会自动同步。")
                }
                Section {
                    DisclosureGroup("连接诊断") {
                        LabeledContent("协商协议", value: model.device.negotiatedProtocol)
                        LabeledContent("最近设备指令", value: model.device.lastCommandID.map(String.init) ?? "--")
                        if case let .failed(message) = model.device.connection {
                            Text(message).font(.footnote).textSelection(.enabled)
                        }
                    }
                }
                Section("定位") {
                    statusRow("搜索位置", symbol: "location", value: searchLocationStatus, color: .secondary)
                    if model.searchLocationStatus == .permissionDenied {
                        Button("前往设置开启定位", action: openSystemSettings)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(WaymateTheme.background)
            .tint(WaymateTheme.accent)
            .navigationTitle("我的圆屏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showsDeviceDetails = false }
                        .accessibilityIdentifier("device-details-done")
                }
            }
            .accessibilityIdentifier("device-details-sheet")
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func statusRow(_ title: String, symbol: String, value: String, color: Color) -> some View {
        LabeledContent {
            Text(value).foregroundStyle(color).multilineTextAlignment(.trailing)
        } label: {
            Label(title, systemImage: symbol).foregroundStyle(Color.primary)
        }
        .font(.body)
        .padding(.vertical, 4)
    }

    private func failureMessage(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.subheadline)
            .foregroundStyle(Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    // MARK: - User-facing state

    private func placeSubtitle(_ place: PlaceSearchResult) -> String {
        let area = place.displayArea.isEmpty
            ? [place.city, place.district].filter { !$0.isEmpty }.joined(separator: " · ")
            : place.displayArea
        var parts = [area, place.address].filter { !$0.isEmpty }
        if let distance = place.distanceM, distance >= 0 {
            let distanceText = distance >= 1_000
                ? String(format: "%.1f km", distance / 1_000)
                : "\(Int(distance.rounded())) m"
            parts.append("距你 \(distanceText)")
        }
        return parts.isEmpty ? "查看路线" : parts.joined(separator: " · ")
    }

    private var deviceStatus: String {
        switch model.device.connection {
        case .connected: return model.deviceReady ? "已连接" : "正在准备"
        case .scanning: return "正在寻找圆屏"
        case .connecting: return "正在连接"
        case .failed: return "连接未成功"
        case .bluetoothUnavailable: return "蓝牙不可用"
        case .idle: return "未连接"
        }
    }

    private var deviceName: String {
        switch model.device.connection {
        case let .connected(name), let .connecting(name): return name
        default: return "WAYMATE"
        }
    }

    private var deviceDetail: String {
        switch model.device.connection {
        case .connected:
            return model.deviceReady ? "圆屏已就绪，可以接收导航指引。" : "正在准备导航同步，请稍候。"
        case .failed:
            return "暂时无法连接。请确认圆屏已开机并靠近手机，再试一次。"
        case .bluetoothUnavailable:
            return "请开启手机蓝牙，并允许 WAYMATE 使用蓝牙。"
        case .scanning, .connecting:
            return "请将已开机的圆屏放在手机附近。"
        case .idle:
            return "连接你的圆屏，在车把上查看导航。"
        }
    }

    private var connectionActionTitle: String {
        switch model.device.connection {
        case .connected: return "断开连接"
        case .scanning: return "停止搜索"
        case .connecting: return "取消连接"
        case .failed: return "重新连接"
        case .idle, .bluetoothUnavailable: return "连接圆屏"
        }
    }

    private var searchLocationStatus: String {
        switch model.searchLocationStatus {
        case .available: return "已获取"
        case .preparing: return "获取中"
        case .permissionDenied: return "未获授权"
        case .unavailable: return "暂不可用"
        }
    }

    private var hasNavigationEstimate: Bool {
        model.navigationComponentState.isNavigationValid
    }

    private var remainingDuration: String {
        hasNavigationEstimate ? model.remainingDurationText : "—"
    }

    private var remainingDistance: String {
        hasNavigationEstimate ? model.remainingDistanceText : "—"
    }

    private var locationStatus: String {
        if model.isDemoActive { return "演示位置" }
        if model.navigationComponentState.locationValidity.isStale { return "位置已过期" }
        return model.navigation.hasUsableFix ? "已获取" : "获取中"
    }

    private var trafficStatus: String {
        if model.isDemoActive { return "演示中" }
        if model.navigation.trafficRequestInFlight { return "更新中" }
        switch model.navigation.networkName {
        case "online": return "在线"
        case "connecting": return "正在连接"
        case "offline": return "离线"
        default: return "--"
        }
    }

    private func trafficTint(_ candidate: RoutePreviewCandidate) -> Color {
        switch candidate.trafficSummary {
        case "拥堵较多": return WaymateTheme.error
        case "部分路段缓行": return WaymateTheme.warning
        case "路况顺畅": return WaymateTheme.connected
        default: return .secondary
        }
    }
}
