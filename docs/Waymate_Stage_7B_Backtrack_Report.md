# Waymate Stage 7B — Round Display Backtrack Integration

2026-10-07，Asia/Shanghai。基线 HEAD `351c213`。完成 Backtrack 独立圆屏生产接线、协议扩展、分段 geometry、页面、重连恢复与软件回归。**未刷机，圆屏 Backtrack 真机未验收。** 未 commit、未 push、未修改 design/。

## Existing BLE Capability

修改前 v1 不能语义正确表达 Backtrack。NavigationSnapshot 的 phase/maneuver/road/traffic/ETA 属于普通导航；RouteGeometry 仅连续 24 点 Navigation window，没有 segment break；MapScene 是 GCJ-02 道路/建筑背景，不能冒充实际 breadcrumb；page 只有 Navigation/Speed/Compass/Music。已有 route token/generation 是 Navigation 身份，不能借给 Backtrack。

可复用的是帧、CRC、分片、顺序、ACK、capability、连接 epoch、write pacing、watchdog、reconnect/resync，以及 generic PageSelected。完全不改协议，最多维持 Stage 7A 的 Speed fallback 和已有手动仪表；无法展示真实 Backtrack 箭头、状态或 breadcrumb。修改前完整链路审计见 [Audit](Waymate_Stage_7B_Backtrack_Audit.md)。

## Protocol Decision

采用最小 additive v1 extension：

| 新增 | 值 | 用途 |
| --- | --- | --- |
| BacktrackState | `0x15` | 独立指导事实、位置有效性、方向、距离、进度和 page |
| BacktrackGeometry | `0x16` | 固定 WGS84 实际轨迹的分段显示投影 |
| CapabilityBacktrack | `1 << 8` | 既有 ConnectionStatus handshake 的能力位 |
| DisplayPage::Backtrack | `4` | 真正独立 Backtrack 页面 |

帧 version=1、payload revision=1、服务/characteristic UUID 保持不变。旧 packet byte layout 不改；NavigationSnapshot 仍只接受原 0–3 page。DeviceCommand byte layout 不改，只有 PageSelected 接受新 enum 值；无 Start/End Backtrack device command。

支持新 capability 的 firmware 收到独立消息和 page 4。旧 firmware 只收到原 packet/page 与 Speed fallback，自动 Media/手动 Compass 也继续用原选页 packet。用隔离 HEAD 原 codec 实测：未知 `0x15` 被安全拒绝，随后原 NavigationSnapshot 仍可解码；现有 golden vectors 全部通过。逐字节 contract、校验和发送成本见 [BLE Backtrack extension](../shared/protocol/ble-backtrack-v1.md)。

## Backtrack Production Chain

`BacktrackSession` → `AppModel` → `PresentationCoordinator / PresentationDriver` → `BLEBacktrackStateCache / ESP32BLECentral` → `MotoBLEProtocolBridge / shared codec` → `NimBLE transport` → `PhoneNavBridge` → `NavPresenter.update_backtrack` → `shared/nav_ui`。

- BacktrackSession 是唯一进度、目标、offTrack、arrival owner；AppModel 在原 Ride 的 SharedLocationSource callback 消费同一个真实 fix。
- Coordinator 决定 Primary Component；Driver 保留手动页面、临时 Media、urgent transition 和 resync。
- 手机 cache 从 immutable route 构建一次 display geometry，仅更新轻量状态；完整 UUID 16 bytes + 非零单调 UInt32 generation 与 Navigation route token/BLE session 分离。
- transport 按 existing protocol-ready gate 与 capability 发送；只在 Backtrack 新 session/重连/reset 发送 geometry。普通进度在新 firmware 上不重复发送 idle Navigation baseline；旧 firmware 保留原选页路径。
- ESP32 接收、校验、缓存并消费事实；Presenter 只做 WGS84 → 像素的 north-up overview 投影，nav_ui 只绘图和显示。未增加第二套 matching/offTrack/arrival。

Navigation → Backtrack：手机先结束 Navigation，发送真实 idle Navigation baseline；逐块 geometry 全部 ACK 后才发送 BacktrackState/page。Backtrack → Navigation：inactive tombstone 在新的 Navigation geometry/snapshot 前发送。ESP32 独立存储两类数据，Backtrack active 清除 Navigation route display geometry；不混合两条路线或 GCJ-02 背景。

## Round Display

| 状态 | 实际显示 |
| --- | --- |
| Normal | BACKTRACK、方向箭头、42 m、FOLLOW TRAIL、2.4 km remaining、分段 breadcrumb |
| Off-track | Amber OFF TRACK / RETURN TO TRAIL、手机给出的接回目标方向和距离 |
| Arrived | START REACHED / RIDE STILL ACTIVE、0 m remaining，隐藏指导箭头 |
| Invalid/paused | WAITING FOR GPS 或 RIDE PAUSED、`--`、DIRECTION UNAVAILABLE，隐藏位置 marker/箭头 |
| Recorded gap | TRAIL GAP，地图断开，指向手机 runtime 选择的下一实际 endpoint |
| Display capacity unavailable | TRAIL TOO LARGE；手机指导继续，不伪造连接线 |

没有 LEFT TURN、RIGHT TURN、REROUTING、RIDE COMPLETE、road、traffic 或 ETA。有效 course 时只使用手机计算的相对方向；否则绝对 bearing，标注 NORTH UP。地图始终 north-up，相对箭头会注明 RELATIVE / MAP NORTH UP；ESP32 IMU 不参与 Backtrack 进度或箭头的业务判断。

保持 Stage C/C.2 black、Ice、White、Graphite、Amber 与既有 Inter/Noto 字体。文案仅新增英文，无新中文 subset。runtime glyph 检查、`lv_text_get_size` 圆形 chord 检查和人工 framebuffer 预览均通过。11 个真实 LVGL 测试 framebuffer 预览：[Contact sheet](ui/stage7b-backtrack/contact-sheet.png)、[Normal](ui/stage7b-backtrack/backtrack-normal.png)、[Off-track](ui/stage7b-backtrack/backtrack-off-track.png)、[Arrived](ui/stage7b-backtrack/backtrack-arrived.png)、[Gap](ui/stage7b-backtrack/backtrack-route-gap.png)。这些是 host fixture render，不能代替面板实物验收。

## Geometry

唯一 source 是 Stage 7A 启动时固定的 BacktrackRoute snapshot。不是继续增长的 RideSession.track，也不是 NavCore/AMap route。

每段独立 RDP 显示简化，初始约 3m metric tolerance，按点数/工作量上限提高 tolerance。保留每段 endpoints、singleton、原 segment index、原 cumulative positions、UUID/generation。最多 256 点；每轮计算预算 source count × 128，病态锯齿不会无限工作。简化仅影响圆屏，源 route 与 iPhone matching 完全不改。若必须保留的 endpoints 本身超过 256，明确显示几何不可用，不连接或静默丢失断段。

每 chunk ≤24 点；不同 segment index 永不连线，包括 chunk 边界。完成部分 Graphite，剩余 Ice；progress 来自原 route 的累计距离，Presenter 的线段插值只用于颜色显示。绘制是一张固定实际 trail overview，长距离可能压缩到很小的屏幕尺度。

一个 chunk 一个 ACK，既有 BLE fragmentation/CRC/sequence/reassembly；同一时刻只有一个 geometry chunk 等 ACK。计时从末帧实际写出开始，失败/timeout 重试使用新 sequence，连续三次失败走原 reconnect。完成 geometry 前不切到空 Backtrack 页面；普通 progress 只发 48-byte State。

## Page Ownership

Backtrack 是 Coordinator 的真实 primary/home。普通 progress、重复 offTrack、rejoin 不抢手动 Compass/Media；新的 offTrack transition 与 arrived transition 抢回一次。到达/有效 offTrack 事实优先于临时 Media；普通 Backtrack 允许原 5s Media temporary，expiry reevaluate 回 Backtrack。用户主动选择 Media 可停留。

Backtrack active 时原 swipe order 的 Home 替换成 Backtrack：Backtrack → Speed → Compass → Media。结束后恢复原 Navigation/Ready Home。未增加复杂手势或 physical Home shortcut。Start/End 只在 iPhone。

## Reconnect

断开只清设备 display/delivery，手机 Backtrack/Ride 继续运行。protocol ready 后：重新评估 Home/Media expiry → 真实 baseline → 同 UUID/generation 的 geometry 全量分块恢复 → 最新 progress State → Backtrack Home。

不重建 snapshot，不把 progress 归零，不 Start Backtrack，不重播 device command。End 保留 inactive tombstone；接收端拒绝同 generation 的 active/geometry 复活以及低 generation/不匹配 UUID 的消息。更换 phone process/connection 的旧包由既有 BLE session/epoch/sequence gate 拦截。Ended session reconnect 只恢复 cleared state 与 Speed/Ready。End Backtrack 不 End Ride；Ride active 回 Speed，无 Ride 回 Ready。

## Performance

iPhone 16 Pro / iOS 18.6 Simulator，合成显示样本；实际计时只属于此 host：

| Source points | Display points | Tolerance | Geometry chunks / 182-byte frames | Frame bytes | Simplification |
| --- | --- | --- | --- | --- | --- |
| 100 | 5 | 3m | 1 / 1 | 113 | 0.078ms |
| 1,000 | 40 | 3m | 2 / 5 | 682 | 0.879ms |
| 7,000 | 91 | 12m | 4 / 11 | 1,530 | 82.46ms |
| 7,000 pathological zigzag | 2 | 48m | 1 / 1 | 71 | 284.58ms |

最后一行展示 adaptive display fidelity 的代价：小尺度锯齿会被显示简化，全部 source points 仍供手机 matching。简化只在 session start 构建一次；reconnect 重发已有显示投影。

理论最大 256 点：11 chunks；frame182 为 32 frames / 4,309B；frame20 为 492 frames / 9,829B。15ms pacing 下，仅 geometry 帧的写出下界约 0.48s / 7.38s，实际还需 ACK/heartbeat/连接时间。每个小 MTU chunk 最多46帧，以 queued≤32 开始发送，低于既有128-frame队列上限。State 为一帧60B（frame182）或六帧120B（frame20），共享200ms coalescing。

Native LVGL 最大256点/4段/100 projected frames：board-parity 40-row case 202.8ms，320-row case 204.4ms。state struct 3,100B；接收/呈现 geometry vectors 各最多256点，按 native ABI 每份约4KiB。渲染 O(256)，无每个点一个 LVGL object。既有64KiB internal +2MiB external LVGL pool 下两种 partial buffer 均通过，最终58,480B used /66,608B peak。设备 PSRAM pool 配置保持不变；这些不是ESP32 live heap或实际FPS。ESP-IDF app binary 1,425,152B，8MiB app partition 尚余约83%。

## Tests

| 检查 | 最终结果 |
| --- | --- |
| 隔离 HEAD 全 AppTests | 226/226 |
| 最终全 AppTests，含 Stage 7A/7B、Presentation、Ride、Navigation、Stage 5/6、BLE/map | **238/238** |
| 新增 BacktrackDisplayTests | **12/12** |
| Swift package | **19/19** |
| Native C++ aggregate suites | **9/9** |
| LVGL 圆屏字体、安全区、正常/偏离/到达/定位无效/长距离/未知目标/断段/容量 | **通过，11张预览** |
| 64KiB +2MiB LVGL pool，40-row /320-row | **两者通过** |
| 既有 Backtrack UI | **3/3** |
| 旧 HEAD codec 对未知0x15安全性与后续原包 | **通过** |
| 原 BLE golden vectors | **通过** |
| XcodeGen | **成功** |
| Unsigned iPhoneOS | **BUILD SUCCEEDED** |
| ESP-IDF fullclean +full build | **成功，未刷机** |
| git diff --check | **通过** |
| 在线导航 UI：当前 /隔离 HEAD | **0/1 /0/1，同 WaymateUITests.swift:390 搜索结果等待失败** |

在线用例均在 `place-result-0.waitForExistence(timeout:20)` 失败，未进入 route start；不能据此声称在线 provider 导航闭环通过。早期复用 DerivedData 的结果包出现 CAS `mkstemp` 保存警告，XCTest 日志已有独立完整结果；最终换新 DerivedData/显式 resultBundlePath 保存成功。ESP-IDF 的 SDK `-Wpedantic` 与 iPhoneOS 的无 AppIntents metadata 警告不影响 build。

用户要求的 coverage 对照：

| 编号 | Coverage / 证据 |
| --- | --- |
| 1–10 | shared protocol normal/offTrack/arrived/invalid flags、UUID/generation/max distances、未知 type、逐字节 truncation；native bridge stale identity/generation；Swift state projection |
| 11–15 | 单/多段、endpoint/singleton/gap、简化、generation；跨chunk间断明确保留 |
| 16–20 | production ACK delivery 普通进度不重发、reconnect reset、stale geometry 拒绝、End clear/tombstone、Navigation geometry 不混合 |
| 21–27 | BacktrackPresentationTests +新增 arrival takeover：start/no page spam/manual Compass/new/repeated offTrack/rejoin/arrived |
| 28–32 | 临时 Media/expiry/manual Media；End 选择 Speed 或 Ready |
| 33–40 | 同UUID/generation/progress恢复、geometry恢复、expired不复活、sender无command replay；既有 AppModel lifecycle tests 验证无第二Start且Ride独立 |

关键 test methods：`test_backtrack_additive_protocol`、`test_backtrack_geometry_state_ordering_tombstone_and_reconnect`、`test_backtrack_product_states`、`testProductionDeliveryACKOrderingProgressDedupAndReconnect`、`testLegacyPeerKeepsOriginalPageSelectionPackets`。完整 native suite 还包含 coordinates/NavCore/NavApp/NavPresenter/epoch/heading fusion/PhoneNavBridge 原回归。

可复查结果：

- `/private/tmp/waymate-7b-final-tests4.xcresult` 与 `/private/tmp/waymate-7b-final-ios-test.log`
- `/private/tmp/waymate-7b-head-ios-test.log`、`waymate-7b-head-online.log`、`waymate-7b-online.log`
- `/private/tmp/waymate-7b-native-test.log`、`waymate-7b-render.log`、`waymate-7b-board40.log`、`waymate-7b-board320.log`
- `/private/tmp/waymate-7b-swift.log`、`waymate-7b-iphoneos.log`、`waymate-7b-idf-build.log`、`waymate-7b-backtrack-ui.log`

## Architecture Check

| 检查 | 结果 |
| --- | --- |
| 伪造 NavigationSnapshot | 否；发送原 NavCore snapshot，仅原 page selection投影 |
| 修改 NavCore/Stage 7A matching | 否 |
| Backtrack 调 route provider/AMap | 否 |
| ESP32 第二套 Backtrack算法 | 否；只有消费/像素投影/颜色分割 |
| 新 CLLocationManager /location owner | 否；原 SharedLocationSource |
| Ride 独立 | 是；Backtrack start/end/reconnect不停止Ride |
| BLE schema | additive新增2个message、capability和page；原layout/revision/UUID不变 |
| Manual browsing | 保留；只有新urgent transition/primary变化/resync才automatic选页 |
| RideStore/GPX/Share Card/design/ | 未修改 |
| 历史/任意目标/Android/GNSS/其他模块扩展 | 未开始 |

## Real-device Plan

晚间使用本轮 app/firmware 统一验收。本轮不执行安装/刷机：

1. 连接支持 Backtrack capability 的新固件，确认Ready；Start Ride。
2. 实际走一段含转弯路线，记录向外轨迹与距离。
3. iPhone Start Backtrack；圆屏在geometry完成后自动进入Backtrack，记录首次显示时延，确认无空页面/Navigation残线。
4. 对照iPhone UUID对应的固定轨迹、remaining与target距离，继续返程；Ride新增轨迹不改变breadcrumb。
5. 手动滑Compass，持续正常progress确认不抢页。
6. 故意偏离当前附近trail：第一次OFF TRACK用Amber抢回；重复偏离更新不持续抢页。
7. 回到trail，核对提示解除与进度单调；正常rejoin不抢手动页。
8. 正常状态触发Media temporary，5秒expiry回Backtrack；另测manual Media可停留。
9. ESP32断电/重开并BLE reconnect，确认原UUID/session、geometry、已走progress与Home恢复；不需要再按Start。
10. BLE断开期间确认手机指导、Ride记录继续；回来后同轨迹恢复。
11. 到实际起点，圆屏START REACHED抢回；不显示RIDE COMPLETE，Ride仍active。
12. iPhone End Backtrack，确认geometry/state清除并回Speed，Ride仍active、返程仍在该Ride；再End Ride核对完整record。
13. 另测无Ride/已结束Backtrack重连回Ready/Speed，不能复活旧session；Navigation↔Backtrack双向确认后仅一条路线。
14. 若有实际暂停/GPS断段，确认地图断开与TRAIL GAP，没有跨gap假连接线。
15. 对照真面板检查BACKTRACK/OFF TRACK/START REACHED/FOLLOW TRAIL、42 m/2.4 km的字号、baseline、圆边与glyph；记录长轨迹重连时延、实际帧率/卡顿与设备heap。

## Remaining

- 真机 Backtrack 验收
- arbitrary prior point
- History Backtrack
- crash recovery
- GNSS hardware

以上未开始。

## Changes

完整文件清单如下（generated Xcode project/build artifacts为ignored，不作为source更改）。

- `platforms/esp32/main/ble_nav_transport_nimble.cpp`
- `platforms/esp32/main/phone_nav_bridge.cpp`
- `platforms/esp32/main/phone_nav_bridge.h`
- `platforms/ios/App/Adapters/BLE/ESP32BLECentral.swift`
- `platforms/ios/App/Adapters/BLE/MotoBLEProtocolBridge.h`
- `platforms/ios/App/Adapters/BLE/MotoBLEProtocolBridge.mm`
- `platforms/ios/App/AppModel.swift`
- `platforms/ios/App/BacktrackView.swift`
- `platforms/ios/App/PresentationCoordinator.swift`
- `platforms/ios/App/PresentationDriver.swift`
- `platforms/ios/AppTests/BacktrackWiringTests.swift`
- `platforms/ios/AppTests/PresentationProductionWiringTests.swift`
- `shared/ble_protocol/include/moto/ble_protocol/ble_protocol.hpp`
- `shared/ble_protocol/src/ble_protocol.cpp`
- `shared/nav_presenter/CMakeLists.txt`
- `shared/nav_presenter/include/moto_nav_presenter.hpp`
- `shared/nav_presenter/src/moto_nav_presenter.cpp`
- `shared/nav_ui/include/moto_nav_ui.h`
- `shared/nav_ui/src/moto_nav_ui.cpp`
- `shared/protocol/ble-navigation-v1.en.md`
- `shared/protocol/ble-navigation-v1.md`
- `tests/native/ble_protocol_tests.cpp`
- `tests/native/esp32_host_stubs/phone_nav_bridge_platform_stubs.cpp`
- `tests/native/moto_nav_ui_stub.cpp`
- `tests/native/nav_ui_render_tests.cpp`
- `tests/native/phone_nav_bridge_tests.cpp`
- `platforms/ios/App/BacktrackDisplayState.swift`
- `platforms/ios/AppTests/BacktrackDisplayTests.swift`
- `shared/protocol/ble-backtrack-v1.md`
- `docs/Waymate_Stage_7B_Backtrack_Audit.md`
- `docs/Waymate_Stage_7B_Backtrack_Report.md`
- `docs/ui/stage7b-backtrack/backtrack-arrived.png`
- `docs/ui/stage7b-backtrack/backtrack-capacity.png`
- `docs/ui/stage7b-backtrack/backtrack-geometry-unavailable.png`
- `docs/ui/stage7b-backtrack/backtrack-invalid-location.png`
- `docs/ui/stage7b-backtrack/backtrack-long-remaining.png`
- `docs/ui/stage7b-backtrack/backtrack-normal.png`
- `docs/ui/stage7b-backtrack/backtrack-off-track.png`
- `docs/ui/stage7b-backtrack/backtrack-paused.png`
- `docs/ui/stage7b-backtrack/backtrack-route-gap.png`
- `docs/ui/stage7b-backtrack/backtrack-trail-gap.png`
- `docs/ui/stage7b-backtrack/backtrack-unknown-target.png`
- `docs/ui/stage7b-backtrack/contact-sheet.png`
- `docs/ui/stage7b-backtrack/index.json`

## Git Status

完整 `git status --short --branch` 输出：

```text
## main...origin/main
 M platforms/esp32/main/ble_nav_transport_nimble.cpp
 M platforms/esp32/main/phone_nav_bridge.cpp
 M platforms/esp32/main/phone_nav_bridge.h
 M platforms/ios/App/Adapters/BLE/ESP32BLECentral.swift
 M platforms/ios/App/Adapters/BLE/MotoBLEProtocolBridge.h
 M platforms/ios/App/Adapters/BLE/MotoBLEProtocolBridge.mm
 M platforms/ios/App/AppModel.swift
 M platforms/ios/App/BacktrackView.swift
 M platforms/ios/App/PresentationCoordinator.swift
 M platforms/ios/App/PresentationDriver.swift
 M platforms/ios/AppTests/BacktrackWiringTests.swift
 M platforms/ios/AppTests/PresentationProductionWiringTests.swift
 M shared/ble_protocol/include/moto/ble_protocol/ble_protocol.hpp
 M shared/ble_protocol/src/ble_protocol.cpp
 M shared/nav_presenter/CMakeLists.txt
 M shared/nav_presenter/include/moto_nav_presenter.hpp
 M shared/nav_presenter/src/moto_nav_presenter.cpp
 M shared/nav_ui/include/moto_nav_ui.h
 M shared/nav_ui/src/moto_nav_ui.cpp
 M shared/protocol/ble-navigation-v1.en.md
 M shared/protocol/ble-navigation-v1.md
 M tests/native/ble_protocol_tests.cpp
 M tests/native/esp32_host_stubs/phone_nav_bridge_platform_stubs.cpp
 M tests/native/moto_nav_ui_stub.cpp
 M tests/native/nav_ui_render_tests.cpp
 M tests/native/phone_nav_bridge_tests.cpp
?? design/
?? docs/Waymate_Stage_7B_Backtrack_Audit.md
?? docs/Waymate_Stage_7B_Backtrack_Report.md
?? docs/ui/stage7b-backtrack/
?? platforms/ios/App/BacktrackDisplayState.swift
?? platforms/ios/AppTests/BacktrackDisplayTests.swift
?? shared/protocol/ble-backtrack-v1.md
```
