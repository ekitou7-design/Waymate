# Stage 7 pre-implementation Architecture Audit

2026-10-07 Asia/Shanghai。HEAD `9ab28327ec5d0ee6f31a088ff418a091264fe977`。进入工作区只有未跟踪 design/，不修改。

## Ownership and audit answers

1. AppModel 的 private Published RideSession 唯一拥有 active track、采样、segment 和指标。rideTrack 是只读投影；RideRecord 是 stop 时产生的持久化值。RideStore 是 actor，schema v1，本轮不修改。
2. CoreLocationNavigationSource 提供 NavigationFix：WGS84、timestamp、horizontalAccuracy、speed、course。SharedLocationSource 将同一连续源交给 Navigation 和 Ride。Backtrack 在 Ride callback 消费同一 fix；不新增 manager/subscription。SearchLocationBiasSource 是已有独立 one-shot 搜索源。
3. RideSession 在 pause/resume、>15s GPS gap 断 segment，stationary→motion 也可断 segment。每段内距离才计入 ride distance；2 秒/至少 3m 采样，未知速度受 accuracy floor 限制。
4. 可直接读 rideSession.track。启动构建 immutable BacktrackRoute，之后不追加返程点，也不改变 RideSession；新返程仍正常录制。
5. BLE RouteGeometry 仅一条连续 polyline、最多 24 个 local window 点，route_token/generation 与 NavigationSnapshot 匹配。没有 segment break 或 guidance source 字段。MapScene 虽有 road spans，但语义是道路/建筑背景，不能把实际 trail 伪装成道路。
6. 采用用户明确允许的 iPhone 完整 V1。Round Display Backtrack = **Not wired**；已有 Speed 页仅为回退，不能称 Backtrack Home/箭头/路线。BLE v1 不修改。
7. Backtrack 不拥有 start/stop 定位，Ride 订阅提供 fix；Navigation.stop 仅释放 Navigation 订阅。不会争抢连续源。
8. AppModel 加入双向显式模式切换确认。所有 live/demo Navigation 启动边界防止并行指导；确认前不结束旧 guidance。paused Ride 禁止启动，active Backtrack 随 pause 停止指导、resume 后等新 fix。
9. Coordinator 增加独立 backtrack primary/input/reason，Driver 复用 manual browsing、Media expiry、新 urgent event 和 resync。BLE page 仍只选现有四页；Backtrack 映射 Speed fallback，概念 decision 独立。
10. iPhone 可复用品牌、MapKit、实际 Ride segment 绘图方法、Ride controls。ActiveNavigationView/NavPresenter/nav_ui 依赖 NavCore phase/maneuver/road/ETA，不能用虚构值复用为 Backtrack。没有修改 renderer 或字体。

## Traced files

RideSession.swift（含 RideRecord/Point）、RideStore.swift、AppModel.swift、PresentationCoordinator.swift、PresentationDriver.swift、NavigationComponentState.swift、SharedNavigationRuntime.swift、SharedLocationSource.swift、CoreLocationNavigationSource.swift、ContentView.swift、RideMetricsView.swift、ActiveNavigationView.swift、RideDetailView.swift、RideRouteMap.swift、RideHistoryView.swift。

ESP32BLECentral.swift（cache、selection、codec input、reconnect baseline）、BLE v1 header/schema、phone_nav_bridge.cpp（consume_navigation/geometry、route token、IMU anchoring）、moto_nav_presenter.cpp、moto_nav_ui.h/.cpp（四页、maneuver、道路及 REROUTING）、相关 Ride/Presentation/Navigation/store/export/UI tests。后续验证沿用现有 XcodeGen project.yml 和 package。

## Algorithm plan, after audit

纯 Swift immutable route：反转连续 segment 和段内 points，保留 singleton/gaps。至少 3 个有效点、50m 段内累计距离、20m 空间展开。无效点不连接，不能确认起点时拒绝启动。

保守 local matching：只搜索当前 segment 进度附近，限制每次可前进距离，monotonic progression；30m 目标前视不跨 gap。到段末进入 TRAIL GAP，指向下一真实 endpoint，接到下一段才继续。Gap 不计距离、不绘连接。

Poor/stale/跳点不推进；offTrack 考虑 accuracy；到达须已接近最后段末且进入起点半径。所有阈值固定、可测试，无 provider reroute、无 ETA。
