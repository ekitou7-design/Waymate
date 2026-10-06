# Waymate UI Redesign Stage B — iPhone Product Experience

2026-10-06 · 基于 HEAD `c171d04` · 未 commit / push。源码实施完成；验证结果与截图见下文。

# UI Audit

修改前审计先于 UI 改动写入 [Audit](Waymate_UI_Stage_B_Audit.md)。原来三张主页面都用 insetGrouped List，Ride Section 总是位于最前。首页缺少品牌与就绪层级，暂停差别不明显，路线地图高度只有 270pt，导航没有展开真实 maneuver。媒体只有底层 Apple Music / BLE 通路，没有 iPhone 入口。设备信息、隐私、Demo 与主要动作在首页混排。

修改前完整测试：AppTests 123/123；UITests 9/16，通过以外的 7 项全部在本轮改动前复现。

# New Information Architecture

单一 NavigationStack 保留，以 AppModel 的 `isNavigationActive` / `selectedPlace` 推导路径：

`Idle 或 Ride Home → 目的地搜索 → Route Preview → Navigation → Idle 或 Ride Home`

Ride active/paused 都可以搜索和规划。Start Navigation 自动创建 Ride 仍交给 Stage 3C；End Nav 清除导航目的地，回到当前 Ride；End Ride 仅结束记录，当前 Navigation 继续。Device、Offline Maps、Media 是可主动打开的辅助 sheet；没有 Tab Bar、新 Router 或深层产品导航。Demo 保留在“更多”，进入后明显标记模拟位置。

# Idle

**Implemented**：W Logo 与系统字体 waymate 名称；真实 LOCATION REQUIRED / SETUP REQUIRED / CONNECT DISPLAY / WAITING FOR GPS / READY；Phone ↔ Display Wayline；清晰搜索框和 START RIDE；真实 Recent 有数据时才显示；Offline Maps、Device、Media 与“更多”辅助入口。未配置网关时显示真实设置入口。

READY 仅表示当前已知的定位、网关配置与显示协议就绪，不宣称网络或路由服务健康。没有全局网络连通性投影，因此没有凭猜测显示 OFFLINE Hero。

# Ride

**Implemented**：真实 elapsed、moving、distance、optional current speed；大字号等宽数字；RIDE PAUSED 与 Amber 区别；Navigate、Pause/Resume、End Ride；未知速度显示 `--`。按钮直接调用现有 AppModel 动作。

End Ride 使用轻量 confirmationDialog，取消保持记录，确认调用 `stopRide()`。对话框说明依当前导航状态变化；没有改变 RideRecord 或生命周期算法。现有 UI 生命周期测试覆盖暂停、恢复、取消结束、确认结束和结束记录提示。

TimelineView 移入 RideMetricsView，每秒只重新计算指标子树；地图没有 timer，没有新增循环任务、昂贵 ViewModel 或路线计算。

# Route Preview

**Implemented**：地图置于目的地之后、候选之前，至少 300pt，通常占可用区域 52%；复用 RouteOverviewMap / MKMapView 和原有 geometry、坐标转换、相机与 renderer 缓存。保留全部候选、ETA、距离、交通、selected route、loading、failure、设置权限、下载所选路线周边及原有 identifiers。

选中候选使用 Ice 与左侧短 Wayline；其他候选保持 neutral。START NAV 仍调用 `toggleNavigation()`，没有重复 Start Ride，也没有偷偷 Resume paused Ride。规划失败时同一个动作可重新规划。

**视觉验收未完成**：在线搜索在修改前和修改后都未返回测试所需结果，没有现成可信的 Route Preview UI fixture；没有向生产路径加入假地点/路线来截图。地图和候选代码已构建，既有 RoutePreviewSupportTests 保持通过；完整页面需可用的真实网关做后续视觉确认。

# Navigation

**Implemented**：以 NavigationComponentState 为输入，显示真实 maneuver 图形/文字、distance to maneuver、instruction、maneuver road、ETA 和 remaining；圆屏状态与地图/媒体放在次级位置，Ride 控制在其后。

明确表达 NAVIGATION / REROUTING / OFF ROUTE / WAITING FOR GPS / LOCATION STALE / NAVIGATION UNAVAILABLE / ROUTE LOADING / ARRIVED。过期、不可用、偏航或重新规划位置不会呈现成正常 live maneuver；保留接受路线的估计时标明等待位置/路线更新。未知 maneuver 用问号与不可用文字，不伪装直行。

Arrived 不结束 Ride；活动记录显示 RIDE CONTINUES，暂停记录说明保持暂停。导航错误优先显示可理解的处理提示，原始信息降级到“错误详情”，不被到达版式隐藏。这里只做文案与图形映射，未修改 NavCore 规则。

**实际视觉检查**：已有 DemoNavigationSession 的明确演示导航，真实来源的右转指令与距离投影。没有把演示截图宣称为真实 GPS 道路测试。warning / rerouting / stale / arrived 的投影分支已有单元测试，未获得这些状态的整页 Simulator 截图。

# Device

**Implemented**：统一 DeviceStatusView 用于 Home、Ride、Navigation、Media；connection 与 negotiatedProtocol 分开表达，不把 BLE connected 当成 protocol ready 或 GPS live。设备入口固定在主导航栏。保留连接/断开/取消/重试及定位设置；sheet 内“连接诊断”展开协议、最近指令和真实 failed message。

未添加电量、传输 live 健康等底层不存在的数据。BLE 不拥有 Ride 生命周期。

# Media

**Implemented**：用户主动打开 Media sheet，没有 5 秒自动关闭；公开已有 AppleMusicRemoteController 回调的只读 PhoneMediaState；曲名、艺人、播放状态、权限/不可用及上一首/播放暂停/下一首直接使用现有控制器。没有新播放器、假封面或第三方通用播放器宣称。

**Future-ready / Not wired**：PresentationCoordinator 的 temporary media event 仍是原有 shadow policy，没有生产事件接线；iPhone 主动 Media sheet 与这项未来自动展示分开。此次没有增加 priority engine，也没有修改 Coordinator policy。

# Brand Integration

主页面使用 Stage A 的 Black、Graphite、Ice、Connected、Amber、Error 和 onAccent/onError；系统字体、scaled hero、monospacedDigit。W Logo 进入首页，wordmark 使用系统文字；未把字体文字声称为 Stage A 的 outlined wordmark 资产。

Wayline 只用于 Phone–Display 连接与 selected route 指示。超大辅助字体时隐藏装饰性的 Phone–Display 线，避免标签断词；真实 DeviceStatus 仍保留。

主 Ride Experience 的 Home / Preview / Navigation 使用局部 dark environment 与 navigation bar 外观；没有全 App `.preferredColorScheme(.dark)`。系统辅助 sheet 保持 Light/Dark 自适应，Media 与地图 sheet 显式按自己的 colorScheme 设置 toolbar，避免浅色“完成”被主导航栏深色偏好污染。

本轮涉及的主 UI、路线 renderer 和离线地图范围绘制已无散落 `.blue` / `.systemBlue`，没有新十六进制 magic color。Apple 底图、系统权限窗口等系统内容仍由系统绘制。

# State Integrity

| 数据 | 来源与未知情况 |
|---|---|
| Ride | AppModel → RideSession；无 UI-only active/paused |
| Speed | rideCurrentSpeed optional；未知 `--`；有效零值仍可显示 0 |
| Distance / times | RideSession 的现有累计数据，单位换算/格式化 |
| Navigation | 真实 NavigationComponentState；无新 phase 或转向策略 |
| BLE | BLEDeviceSnapshot.connection + negotiatedProtocol；无假 connected/live/battery |
| Location | searchLocationStatus / hasUsableFix / isStale；权限与过期明确显示 |
| Traffic | 原有 candidate.trafficSummary、trafficRequestInFlight、networkName；不捏造顺畅 |
| Media | 已有系统 Music 控制器回调；未收到回调为 unavailable |
| Recent | 原有 UserDefaults 数据；不新增示例历史 |

未加入生产 mock。原有明确 Demo 路径继续隔离且有可见说明。

# Architecture Check

| 检查项 | 结果 |
|---|---|
| RideSession / GPS filtering / distance / moving 算法 | 未修改 |
| PresentationCoordinator policy | 未修改 |
| NavCore / SharedNavigationRuntime 业务语义 | 未修改 |
| BLE protocol / ESP32 / shared/nav_ui | 未修改 |
| AMap provider / gateway / 坐标系 / geometry 语义 | 未修改 |
| Media 底层 | 未修改；AppModel 只公开回调值与现有动作 |
| 第二套 state machine / priority engine | 未增加；NavigationReadout 只是无保留状态的 UI 映射 |
| Production mock data | 未增加 |
| PRD / Stage A Logo geometry / AppIcon | 未修改 |

**Needs product/architecture decision**：全局网络就绪的定义、temporary media 生产接线仍需独立决定。本轮没有实施业务变化或 Stage C。

# Accessibility

原 ContentView 的 accessibility identifiers 全部保留，指标 identifiers 随拆分移入 RideMetricsView。包括 Ride start/pause/resume/end/status/metrics/error/record、search、place-result-N、recent-place-N、route map/loading/option-N、Start/End Navigation、destination change、Device、Offline Maps、gateway、privacy 和 Demo。

新增：`home-readiness`、`ride-navigate-button`、`ride-end-confirm`、`navigation-status`、`navigation-maneuver`、`navigation-maneuver-distance`、`navigation-ride-continues`、`media-open-button`、`media-sheet`、`media-done-button`、`media-command-16/17/18`。

Dynamic Type：系统字体和 scaled hero；没有 minimumScaleFactor 或固定页面高度；大字体页面滚动，指标在 accessibility size 改为纵向。Home 的 Accessibility XXXL 搜索与固定设备入口通过交互检查并截图。未逐页完成 Preview、Navigation、Ride 的 XXXL 截图验收。

VoiceOver 基础：关键动作有行为标签，指标有 label/value，装饰图形隐藏，route option 保留 selected trait，媒体图标按钮有操作标签。未运行实机 VoiceOver 全流程或专门的系统 accessibility audit，不能宣称完整无障碍验收。

# Validation

| 检查 | 结果 |
|---|---|
| 修改前 AppTests | 123/123 通过 |
| 最终 AppTests | 126/126 通过；包含 Ride、Navigation、PresentationCoordinator 和新增 3 项 UI readout 测试 |
| Swift package tests | 19/19 通过 |
| 修改前完整 UITests | 16 项：9 通过、7 失败 |
| 修改后完整 UITests | 18 项：11 通过、7 失败；失败名称与修改前完全相同 |
| UI 交互与最终细节复测 | 8/8 UI 通过；最后 sheet/nav 修正后再次 126/126 AppTests 与 2/2 相关 UI 通过；导航设备 toolbar 另加 1/1 UI 与 126/126 AppTests 通过 |
| XcodeGen | generate 成功，生成工程未成为 tracked diff |
| iPhoneOS build | signing disabled，BUILD SUCCEEDED |
| git diff --check | 通过 |

7 项保留失败的分类：

| 测试 | 修改前 / 修改后 | 分类与失败点 |
|---|---|---|
| testLiveShanghaiCitySearchShowsDownloadCoverage | 都失败 | pre-existing / searchable UI 环境；城市搜索框未出现，尚未到达下载接口 |
| testMapDownloadsExposeCitySearchAndReturnHome | 都失败 | pre-existing / searchable UI 环境；城市搜索框未出现 |
| testNearbyDestinationCanBeSelectedAndReturnsToRecentSearches | 都失败 | pre-existing / network-gateway environment；place-result-0 未返回 |
| testRoutePreviewSwipeRightReturnsToSearch | 都失败 | pre-existing / network-gateway environment；place-result-0 未返回 |
| testRoutePreviewSystemBackReturnsToSearch | 都失败 | pre-existing / network-gateway environment；place-result-0 未返回 |
| testRoutePreviewVisualState | 都失败 | pre-existing / network-gateway environment；place-result-0 未返回 |
| testSelectedRouteStartsNavigationAndEndsAtHome | 都失败 | pre-existing / network-gateway environment；place-result-0 未返回 |

第一轮新增的 XXXL 搜索可达性和 Demo 返回后 DisclosureGroup 重复切换属于 Stage B 测试布局适配，已修正并通过复测。浅色辅助 sheet 的按钮对比问题来自视觉检查，已修正局部 appearance / tint。没有删除测试、放宽真实搜索成功断言或把已知失败标成通过。一次针对性复测跳过了 7 项已完整运行并确认的 baseline 失败；之后又运行了包含全部 18 项的完整 UITests。

证据文件（本机临时目录）：

- `/tmp/waymate-stage-b-baseline.log` / `.xcresult`：完整修改前基线。
- `/tmp/waymate-stage-b-release-check.log` / `.xcresult`：修改后完整套件 126 AppTests + 18 UITests。
- `/tmp/waymate-stage-b-complete.log` / `.xcresult`：最后的大字体装饰降级、触控面积调整后 126 AppTests + 8 项 UI 全通过。
- `/tmp/waymate-stage-b-sheets-final.log` / `.xcresult`：最终地图 toolbar 和导航错误详情修正后的 AppTests 与相关 UI 复测。
- `/tmp/waymate-stage-b-swift.log`：Swift package 19 项。
- `/tmp/waymate-stage-b-toolbar-final.log` / `.xcresult`：导航设备 toolbar 最终交互与 AppTests。
- `/tmp/waymate-stage-b-device-delivery-final.log`：最终 iPhoneOS 无签名构建。

测试环境：Xcode 16.4，iOS 18.6，iPhone 16 Pro Simulator。正式 GPS 路径的 UI 生命周期操作用既有 XCTest 位置环境；生产代码没有添加 fixture。

# Visual Review

截图保存在 `docs/ui/stage-b-visuals/`，`index.json` 记录原始测试与 attachment 来源。已查看实际截图，并据此修正大字体装饰文字断行与浅色 toolbar 对比。

| 页面 / 状态 | 截图 |
|---|---|
| Idle，系统 Light / Dark，局部品牌 dark | [Light](stage-b-visuals/idle-light.png)、[Dark](stage-b-visuals/idle-dark.png) |
| Home Accessibility XXXL 与滚动后的搜索 | [Hero](stage-b-visuals/idle-axxxl.png)、[Search](stage-b-visuals/search-axxxl.png) |
| Ride Active / Paused / Ended | [Active](stage-b-visuals/ride-active.png)、[Paused](stage-b-visuals/ride-paused.png)、[Ended](stage-b-visuals/ride-ended.png) |
| Navigation，现有 Demo fixture | [Demo](stage-b-visuals/navigation-demo.png) |
| Device disconnected / unavailable，Light / Dark / XXXL | [Light](stage-b-visuals/device-light.png)、[Dark](stage-b-visuals/device-dark.png)、[XXXL](stage-b-visuals/device-axxxl.png) |
| Media unavailable，Light / Dark | [Light](stage-b-visuals/media-light.png)、[Dark](stage-b-visuals/media-dark.png) |
| Offline Maps root，Light / Dark | [Light](stage-b-visuals/maps-light.png)、[Dark](stage-b-visuals/maps-dark.png) |

Route Preview、真实 active navigation、warning/rerouting、arrived 没有整页截图；具体环境限制与后续验证见各页面及 Follow-up。不把单元投影测试或演示导航截图当成这些页面的完整验收。

# Changed Files

修改：

- `platforms/ios/App/AppModel.swift`：现有 Media 回调投影与操作公开。
- `platforms/ios/App/ContentView.swift`：主信息架构、页面布局、确认对话框、辅助入口、设备诊断。
- `platforms/ios/App/MapDownloadsView.swift`：tokens、背景、sheet toolbar；下载业务未改。
- `platforms/ios/App/RouteOverviewMap.swift`：renderer / marker 颜色 token。
- `platforms/ios/UITests/WaymateUITests.swift`：布局可达性适配、确认取消/提交、Media 与辅助页面 Light/Dark 截图检查。

新增：

- `platforms/ios/App/ActiveNavigationView.swift`
- `platforms/ios/App/DeviceStatusView.swift`
- `platforms/ios/App/MediaView.swift`
- `platforms/ios/App/RideMetricsView.swift`
- `platforms/ios/App/WaymatePrimaryButton.swift`
- `platforms/ios/AppTests/NavigationReadoutTests.swift`
- `docs/ui/Waymate_UI_Stage_B_Audit.md`
- `docs/ui/Waymate_UI_Stage_B_Report.md`
- `docs/ui/stage-b-visuals/index.json`
- `docs/ui/stage-b-visuals/idle-light.png`
- `docs/ui/stage-b-visuals/idle-dark.png`
- `docs/ui/stage-b-visuals/idle-axxxl.png`
- `docs/ui/stage-b-visuals/search-axxxl.png`
- `docs/ui/stage-b-visuals/ride-active.png`
- `docs/ui/stage-b-visuals/ride-paused.png`
- `docs/ui/stage-b-visuals/ride-ended.png`
- `docs/ui/stage-b-visuals/navigation-demo.png`
- `docs/ui/stage-b-visuals/device-light.png`
- `docs/ui/stage-b-visuals/device-dark.png`
- `docs/ui/stage-b-visuals/device-axxxl.png`
- `docs/ui/stage-b-visuals/media-light.png`
- `docs/ui/stage-b-visuals/media-dark.png`
- `docs/ui/stage-b-visuals/maps-light.png`
- `docs/ui/stage-b-visuals/maps-dark.png`

# Follow-up

- 用可用的真实导航网关完成 Route Preview、多路线选择、开始正式 Navigation 的视觉与在线回归；本机测试的网关保存测试使用 nav.example.com，后续请求未得到结果，不以此断言真实服务故障。
- 排查修改前已复现的城市搜索框可达性/系统 searchable 展开问题，分别验证 UI 元素与真实网关请求。
- 真实 iPhone + 圆屏连接下确认 Device protocol-ready 和 GPS warning/arrived 的整页视觉；Apple Music 真机播放与权限状态；补齐各核心页面大字体和 VoiceOver 流程。
- Coordinator temporary media 的正式事件接线与全局 Ready 定义独立评估；未开始 Stage C。

# Git

HEAD 仍为 `c171d04f3eecc5c2b53ef5fa46c3c79849dcb35b`。本轮 5 个 tracked 文件修改，24 个新增文件（含 15 张截图和来源索引）；原有 2 个未跟踪文件保留。没有 commit / push。

最后 `git status --short`：

```text
 M platforms/ios/App/AppModel.swift
 M platforms/ios/App/ContentView.swift
 M platforms/ios/App/MapDownloadsView.swift
 M platforms/ios/App/RouteOverviewMap.swift
 M platforms/ios/UITests/WaymateUITests.swift
?? design/
?? docs/ui/
?? platforms/ios/App/ActiveNavigationView.swift
?? platforms/ios/App/DeviceStatusView.swift
?? platforms/ios/App/MediaView.swift
?? platforms/ios/App/RideMetricsView.swift
?? platforms/ios/App/WaymatePrimaryButton.swift
?? platforms/ios/AppTests/NavigationReadoutTests.swift
?? scripts/ios/generate_waymate_brand.swift
```

`docs/ui/` 的完整新增文件已在 Changed Files 列出；`design/` 与品牌脚本都是原有内容，没有修改。
