# Waymate UI Redesign Stage C — Round Display Product Experience

2026-10-06。先完成 [修改前审计](Waymate_UI_Stage_C_Audit.md)，再实施 renderer。本轮没有 commit / push / 刷机；原 design/ 和 Stage B iPhone 工作区保持原有内容。

# Round Display Audit

真实页面仅 Navigation、Speed、Compass、Music；Boot/Power Off 为终端画面，Idle/Ready/Connecting/Disconnected 是 Navigation 的 lifecycle surface。没有真实 Ride dashboard packet 或消费，未创造 Ride 页面。

手机 NavigationSnapshot.display_page 与本地 swipe → PageSelected 仍控制页面。PhoneNavBridge 保持数据复制、连接降级、IMU fusion、独立 render task 和 board lock。iPhone PresentationCoordinator 为 shadow evaluator，未接入生产 page；temporary Media 的 5 秒 policy 未生产接线，主动 Music 页原本就没有退出 timer。PWR 仍只有现行关机行为。

修改前 NavPresenter 已提供路线、道路、建筑、转向、距离、交通、可选限速、heading；道路文字未显示，stale/off-route/has-next 没有投影给 UI。Compass 有 fix 即显示北向，不能说明低速/相对方向的可靠性。审计中的完整字段来源、测试依赖、内存和 Web 共用范围见 Audit。

# Design Language

- **Wayline**：Stage A W 的两条等宽圆角路径，直接几何绘制；连接/规划使用短连续线路和缓慢 travelling bead。静态 Ready/Disconnected 没有持续 pulse/orbit。路线使用固定宽度圆角线，不引入 theme engine。
- **Palette**：沿用文件内最小固定 palette。圆屏背景 #000000，作为 AMOLED true-black 的设备适配；White #F3F4EF、Ice #B8EDF5、Graphite #303539、Road #42474B、Green #69D494、Amber #E6C84F、Red #FF4B43。道路等级只用既有暗灰差异。
- **Typography**：复用 Montserrat 16/20/28/48 和原 moto_font_nav_16。Speed 用现有48字体2倍缩放，不增加字体包；数字复用原bitmap并统一32px digit advance，不新增atlas；距离固定宽度居中、单位独立，不随数位移动其他元素。Media Latin title 为28，中文回退既有16子集，单行省略。
- **Safe area**：466×466 的圆形 chord 约束。顶部动作/距离、中央地图、底部短道路；Media source 收窄，文字定高，按钮保留大圆形目标。关键文字不放角落；所有 preview 应用 nominal circle mask。
- **Icons**：复用真实8个 UI maneuver，统一粗线/箭头；不扩充 enum。Arrive 使用简洁 Green check。固定方向车标保留真实 heading-up 地图语义，不使用汽车图案。

# Boot

纯黑底中央 Stage A W，100×100几何与品牌资产一致。保持现有单次 opacity fade 和1.25秒启动 cadence；没有 bitmap pipeline、假进度、长动画或文字堆叠。Power Off 仍用现有 Waymate 关机画面。

# Idle

READY + W + PHONE CONNECTED，仅表达现有协议可用状态，不宣称 GPS、网关、Ride 或设备电量健康。连接断开 PHONE LOST；握手/未 ready 时 CONNECTING；规划 ROUTE LOADING。保留已有中文手机操作提示，静态状态不做持续装饰动画。

# Navigation

| 元素 | 实现 |
|---|---|
| map | 真实道路/建筑/route retained；map可视高度从232增至294 design px，顶部opaque hero防止线穿过文字；没有改坐标变换或运动模型 |
| maneuver | 顶部统一几何 glyph；只有 has-next、位置可用且非warning时呈现可执行动作，unknown不包装为直行 |
| distance | 顶部48字号、固定宽度、m/km独立；near与km preview；stale/off-route/rerouting时停止呈现正常动作距离 |
| instruction / road | 首次消费既有 next_road_name：有road显示road，空road用Presenter既有instruction fallback；单行省略，保留中文 |
| route | 主线Ice，周围路暗灰；固定marker与projection不动；异常主线Amber/Red |
| traffic | 现有aggregate traffic映射进度弧Green/Amber/Red，unknown为neutral；未创造分段拥堵信息 |
| warning | REROUTING / LOCATION STALE / WAITING FOR GPS 为顶部大Amber；OFF ROUTE顶部大Red；保持地图空间参照，隐藏正常箭头/动作距离，无闪烁 |
| arrived | 隐藏地图/限速/进度/距离，Green check + ARRIVED，保留输入道路；不显示RIDE COMPLETE、不结束Ride |
| optional limit | 仅输入>0显示；真实provider没提供则隐藏，不新加限速 |

没有修改 route/window identity、generation、scene revision、geometry semantics、projection 或 interpolation。

# Speed

大号真实输入 speed，单位 km/h；轻量Ice弧与6个稀疏刻度，非RPM仪表。Speed availability 只读投影：无fix、stale或非有限/负值 → --；有效零速仍是0。不增加gear、RPM、engine temp、battery等估计值。160三位数预览在圆内。

# Compass

White degree、Ice cardinal、轻量方向ticks，secondary speed，明确标注 DERIVED HEADING。低于现有fusion anchor速度1.5m/s，或已知无fix/stale/nonfinite时，degree为--并隐藏北向ring/cardinal；不声称 ABSOLUTE NORTH。相对gyro融合和低速停转算法原样保留。

**输入边界**：BLE v1 没有独立 course-valid / heading-source 位，且NavCore/packet可能已把未知值归一化。此次保守显示门槛不能恢复上游丢失的有效性信息；这里的heading是DERIVED，不是保证真北的测量值。没有为解决此项修改业务或协议。

# Media

真实source/title/artist与playing；小音乐符号，移除假唱片式placeholder；previous/play-pause/next保留原触控位置和reverse command。暂停为neutral，播放为Ice，Red不用于暂停。中文使用既有glyph子集，Latin fallback；固定buffer的UTF-8截断会丢弃不完整末尾码点，长文本单行省略，不挤到artist。

不连接时清除旧title/artist、显示MEDIA UNAVAILABLE并disabled controls；不乐观切换播放状态，等待手机回传。Like仍仅由已有capability控制，不新增产品承诺。没有album art、fake progress或新增BLE字段。主动Music页超过5秒仍保持，新增native检查确认；temporary policy未改/未接线。

# Connection

Navigation保留真实连接lifecycle owner的overlay，正常guidance不会被短暂CONNECTED画面盖住。其他三个工具页新增短PHONE LOST / LINK NOT READY提示，online时消失；不以network offline推断Bluetooth状态。

当前UI只有offline/connecting/online三个connection enum，CONNECTING同时覆盖握手未ready；不能独立区分物理connecting与协议错误。不创造reconnect次数/电量/假健康状态。已有断线清空与Ready后的snapshot/map/media恢复路径保留，host regression通过。

# Interaction

左右swipe、page callback、Media command/button位置、音乐capability禁用回退、PWR行为不变。没有双击、长按层级、嵌套菜单、新Home shortcut或新expiry策略。视觉图标不是新的业务页面；Stage4未提前实施。

# Data Integrity

| 数据 | 本轮真实性处理 |
|---|---|
| speed | REAL phone sensor input，单位/归一化DERIVED；本层已知unavailable显示--，有效0保留 |
| heading | DERIVED phone course + relative gyro；低速/已知invalid隐藏方向，无真北承诺 |
| route | REAL accepted geometry + DERIVED projection/progress；空间与坐标语义不变 |
| traffic | REAL provider category；unknown neutral，不捏造畅通或分段traffic |
| media | REAL phone callbacks；未知文本空、不编造封面/进度；命令不乐观改状态 |
| connection | REAL既有link/Ready/valid snapshot投影；network与BLE语义分开 |

没有新增ESTIMATED dashboard数据或生产mock。所有新演示数据只在native test可执行程序内，只有显式MOTO_UI_PREVIEW_DIR才导出frame，不经BLE、不进入firmware业务。

已知边界：NavCore现有speed归一化/packet可将上游未知变成0，BLE无独立speed/course-valid位，renderer无法把这种0与真实0完整区分。保持协议限制并记录，不把本层availability投影称为端到端validity修复。中文仍是小型子集，未覆盖字符显示fallback missing glyph；没有删除原中文字段，也不宣称支持任意中文地名。

# Architecture

| 检查 | 结果 |
|---|---|
| BLE protocol / UUID / packet schema | 未修改 |
| NavCore / navigation业务语义 / route provider | 未修改 |
| PresentationCoordinator policy | 未修改 |
| RideSession / RideTracking | 未修改 |
| iPhone Stage B UI / AppIcon | 未修改，原有工作区diff保留 |
| 第二套page policy | 未增加 |
| map coordinate system / packet / geometry | 未修改 |
| PhoneNavBridge / transport / reconnect owner | 未修改 |
| 改动范围 | shared renderer、最小只读Presenter validity字段、native tests、预览脚本与报告 |

moto_ui_state_t新增字段只是内存中的renderer投影；没有序列化到BLE。Web与ESP32一起重新编译。

# Performance

四页与bounded map slots仍一次创建。状态更新只改变保留对象的文字、style、geometry；high-rate motion仍只更新地图/Compass。没有Tick销毁重建树、额外canvas或全量字体。Ready/断线静态不invalidating动画symbol；boot/lifecycle transition使用既有fade。

板端配置host实测：64KiB internal LVGL heap +2MiB extra pool，320-row partial buffer测试最终used 55,280 bytes，max 86,736 bytes；40-row测试max70,608 bytes。该值来自LVGL memory monitor，是host测试中的分配记录，不等同ESP32完整heap/RAM实测。2MiB PSRAM扩展是原有板端配置，保留；仅64KiB池不足以覆盖峰值。

Speed现有bitmap字形缩放会使用中间绘制层，已包含在上述render test；真实AMOLED刷新帧率、PPA/DMA路径与户外可读性仍需设备验收。字体资源文件未改变；最终firmware尺寸与构建日志见Validation。

# Validation

| 项目 | 结果 |
|---|---|
| 修改前native基线 | 9/9通过 |
| 最终native/C++ | 9/9通过，包括真实nav_ui render、Presenter、NavCore、NavApp、BLE golden、epoch、fusion、PhoneNavBridge host、coordinates |
| board parity renderer | 64KiB+2MiB，320-row与40-row两种buffer均通过；determinism、geometry cleanup、motion settle、容量、boot/power-off、unknown、UTF-8、主动Media保持 |
| Swift package | 19/19通过 |
| iOS AppTests | 126/126通过，含Navigation/Coordinator/Ride回归；未再跑与此次改动无关的UITests |
| ESP-IDF | 完整1.75C firmware build成功；bin 0x13ba60 / 1,292,896 bytes，8MiB app partition剩余约85%；未flash |
| Web/shared | 真实共用LVGL renderer在native构建/预览通过；本机无emcmake/emcc，未运行WASM build/browser preview；Web-specific overlay未改 |
| git diff --check | 通过 |

日志：`/tmp/waymate-stage-c-baseline-tests.log`、`/tmp/waymate-stage-c-tests.log`、`/tmp/waymate-stage-c-render.log`、`/tmp/waymate-stage-c-parity-tests.log`、`/tmp/waymate-stage-c-parity-strip-tests.log`、`/tmp/waymate-stage-c-swift.log`、`/tmp/waymate-stage-c-ios-retry.log`与`.xcresult`、`/tmp/waymate-stage-c-idf-delivery-build.log`。

Swift最初的sandbox cache失败通过把module cache置于/tmp解决；Xcode最初sandbox临时文件访问失败后，获自动许可的测试执行成功。没有跳过失败断言或把build当作测试通过。

复现native preview：

```sh
cmake -S . -B /tmp/waymate-stage-c-native -DMOTO_BUILD_WEB=OFF -DCMAKE_BUILD_TYPE=Release
cmake --build /tmp/waymate-stage-c-native --parallel 8
mkdir -p /tmp/waymate-stage-c-frames
MOTO_UI_PREVIEW_DIR=/tmp/waymate-stage-c-frames /tmp/waymate-stage-c-native/tests/native/nav_ui_render_tests
python3 scripts/render_round_display_previews.py /tmp/waymate-stage-c-frames docs/ui/stage-c-visuals
ctest --test-dir /tmp/waymate-stage-c-native --output-on-failure
```

# Visual Review

[20张圆形预览总览](stage-c-visuals/contact-sheet.png)，[来源索引](stage-c-visuals/index.json)。真实 LVGL 466×466 RGB565 framebuffer，经nominal圆形mask；每一张都是明确native test fixture，不代表真实GPS/AppleMusic/BLE骑行采样。已查看总览和关键466px原图，修正warning过小、Media长文本换行、标题对比、Speed刻度过密。不能把host画面等同真机光学/触控/性能验收。

全部预览：

- [arrived.png](stage-c-visuals/arrived.png)
- [boot.png](stage-c-visuals/boot.png)
- [compass-heading-unavailable.png](stage-c-visuals/compass-heading-unavailable.png)
- [compass.png](stage-c-visuals/compass.png)
- [connecting-protocol-not-ready.png](stage-c-visuals/connecting-protocol-not-ready.png)
- [disconnected.png](stage-c-visuals/disconnected.png)
- [idle-ready.png](stage-c-visuals/idle-ready.png)
- [location-stale.png](stage-c-visuals/location-stale.png)
- [maneuver-near.png](stage-c-visuals/maneuver-near.png)
- [media-long-utf8.png](stage-c-visuals/media-long-utf8.png)
- [media-paused.png](stage-c-visuals/media-paused.png)
- [media-playing.png](stage-c-visuals/media-playing.png)
- [media-unavailable.png](stage-c-visuals/media-unavailable.png)
- [navigation-long-text-km.png](stage-c-visuals/navigation-long-text-km.png)
- [navigation-normal.png](stage-c-visuals/navigation-normal.png)
- [off-route.png](stage-c-visuals/off-route.png)
- [rerouting.png](stage-c-visuals/rerouting.png)
- [speed-three-digits.png](stage-c-visuals/speed-three-digits.png)
- [speed-unknown.png](stage-c-visuals/speed-unknown.png)
- [speed.png](stage-c-visuals/speed.png)

# Changed Files

本轮修改：

- `shared/nav_ui/src/moto_nav_ui.cpp`
- `shared/nav_ui/include/moto_nav_ui.h`
- `shared/nav_presenter/src/moto_nav_presenter.cpp`
- `tests/native/nav_ui_render_tests.cpp`
- `tests/native/nav_presenter_tests.cpp`

本轮新增：

- `scripts/render_round_display_previews.py`
- `docs/ui/Waymate_UI_Stage_C_Audit.md`
- `docs/ui/Waymate_UI_Stage_C_Report.md`
- `docs/ui/stage-c-visuals/index.json`
- `docs/ui/stage-c-visuals/arrived.png`
- `docs/ui/stage-c-visuals/boot.png`
- `docs/ui/stage-c-visuals/compass-heading-unavailable.png`
- `docs/ui/stage-c-visuals/compass.png`
- `docs/ui/stage-c-visuals/connecting-protocol-not-ready.png`
- `docs/ui/stage-c-visuals/contact-sheet.png`
- `docs/ui/stage-c-visuals/disconnected.png`
- `docs/ui/stage-c-visuals/idle-ready.png`
- `docs/ui/stage-c-visuals/location-stale.png`
- `docs/ui/stage-c-visuals/maneuver-near.png`
- `docs/ui/stage-c-visuals/media-long-utf8.png`
- `docs/ui/stage-c-visuals/media-paused.png`
- `docs/ui/stage-c-visuals/media-playing.png`
- `docs/ui/stage-c-visuals/media-unavailable.png`
- `docs/ui/stage-c-visuals/navigation-long-text-km.png`
- `docs/ui/stage-c-visuals/navigation-normal.png`
- `docs/ui/stage-c-visuals/off-route.png`
- `docs/ui/stage-c-visuals/rerouting.png`
- `docs/ui/stage-c-visuals/speed-three-digits.png`
- `docs/ui/stage-c-visuals/speed-unknown.png`
- `docs/ui/stage-c-visuals/speed.png`

原有Stage B iOS修改、原docs/ui/stage-b-visuals与Stage A assets、原design/、品牌生成脚本未纳入本轮改动。ESP-IDF生成bin/elf/build目录为已有ignored构建产物。

# Remaining

- Stage4 production presentation wiring、真实Ride dashboard消费、Home physical shortcut、temporary Media生产接线；本轮未开始。
- 在Emscripten环境运行Web/WASM build和共用页面/overlay回归，本机未安装toolchain。
- 1.75C真机光学圆边、触控、PPA/DMA/frame timing、重连后的实际屏幕恢复与真实骑行glanceability验收；本轮未要求刷机。
- 任意中文道路/艺人名字的字体coverage与资源取舍，以及上游speed/course有效性在现行BLE中的表达；当前受已有子集/contract限制，没有假装完成。

# Git

未commit / push。最后工作区状态包括原Stage B修改：

```text
 M platforms/ios/App/AppModel.swift
 M platforms/ios/App/ContentView.swift
 M platforms/ios/App/MapDownloadsView.swift
 M platforms/ios/App/RouteOverviewMap.swift
 M platforms/ios/UITests/WaymateUITests.swift
 M shared/nav_presenter/src/moto_nav_presenter.cpp
 M shared/nav_ui/include/moto_nav_ui.h
 M shared/nav_ui/src/moto_nav_ui.cpp
 M tests/native/nav_presenter_tests.cpp
 M tests/native/nav_ui_render_tests.cpp
?? design/
?? docs/ui/
?? platforms/ios/App/ActiveNavigationView.swift
?? platforms/ios/App/DeviceStatusView.swift
?? platforms/ios/App/MediaView.swift
?? platforms/ios/App/RideMetricsView.swift
?? platforms/ios/App/WaymatePrimaryButton.swift
?? platforms/ios/AppTests/NavigationReadoutTests.swift
?? scripts/ios/generate_waymate_brand.swift
?? scripts/render_round_display_previews.py

```
