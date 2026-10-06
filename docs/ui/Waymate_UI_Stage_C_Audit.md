# Round Display Audit — Stage C

2026-10-06。修改前审计；基于当前源码和 Stage A/B 资源，不将源码检查视为真机验证。原有 Stage B 工作区修改与 design/ 保留。

## Pages / ownership

真实枚举仅 Navigation / Speed / Compass / Music。Boot 和 Power Off 是终端画面；Idle、Disconnected、Connecting、Connected、Ready、Planning 是 Navigation 内的 lifecycle overlay。没有 Ride packet 或 Ride metrics 消费。Navigation 有地图、固定方向车标、下部动作与距离、可选限速、进度弧；道路文字虽投影但未显示。没有独立 Arrived composition。

手机 NavigationSnapshot.display_page → PhoneNavBridge → NavPresenter → nav_ui；本地左右 swipe → nav_ui → PhoneNavBridge.page_changed → snapshot page + reverse PageSelected。Media capability 缺失会禁用 Music 并回退 Navigation。PWR 按钮仅负责长按关机，没有生产 Home shortcut。无双击/复杂菜单；没有生产 long-press Demo activation。

PresentationCoordinator 是 iPhone shadow evaluator，AppModel 输入 mediaInteraction=nil，没有生产 BLE page wiring。其 temporary Media 窗口是 5 秒，但当前圆屏主动 Music 页没有 expiry timer；5 秒 timer 是交互页点隐藏。Stage C 不接线、不新建 page policy。

## Data integrity before changes

| 字段 | 分类 / 来源 / unavailable |
|---|---|
| speed | REAL phone location，单位换算 DERIVED；gps_accuracy_m=0 时 --，但旧投影未消除 gnss_stale 的显示 |
| heading | DERIVED phone course + QMI8658 relative gyro；无磁力计，低速保留/相对积分；旧 UI 把有 fix 当可信北向，BLE/UI 无独立 course-valid flag |
| maneuver / distance | provider maneuver + NavCore 路线进度 DERIVED；8 个 UI 类型，sharp/exit 等折叠为现有 left/right；unknown 折叠 straight，旧 UI 缺 has-next 标志 |
| road / instruction | REAL provider text；Presenter next_road_name 优先 road，空 road 回退 instruction；旧 renderer 没有消费，缺全量中文字体 |
| route / geometry / scene | REAL provider/offline map；projection / interpolation DERIVED；24 route、192 road points/24 spans、128 building points/16 spans；无 geometry 时 unavailable |
| remaining / progress / ETA | DERIVED route projection/provider estimate；进度 percent 不是实测旅行时间 |
| traffic | REAL provider category；unknown 不得包装为畅通；旧进度颜色与 traffic 绑定，无每段道路交通渲染 |
| speed limit | REAL 仅输入非零可用；AMap Web service 不提供，正式路径零/隐藏 |
| media | REAL Apple Music phone callbacks，经 BLE MediaState；shared UI 仅 source/title/artist/connected/playing/like flags；position/duration 虽协议有但没投影，不新增 progress/art |
| connection | REAL link/handshake：offline、connecting（含未 ready）、online（Ready 或有效 snapshot）；无独立 reconnect 次数/协议错误分类 |
| Ride / RPM / gear / battery | unavailable；无正式显示数据，不新增 ESTIMATED 值 |

## Connection / restoration

PhoneNavBridge.on_link_state(false) 清 usable fix、speed、geometry/map、fusion/media；RenderNavigation + RenderMedia 合并请求。Ready/capabilities 与有效 snapshot 推动连接投影。渲染任务在 state-copy 后、board lock 内调用 LVGL，不在 BLE callback 绘图。Stage 0 epoch/session/fragment/watchdog/resync 保持现有 owner。

连接 overlay 当前只位于 Navigation；其他仪表页断线表现为 --，没有明显连接状态。正常导航短暂 Connected overlay 可遮挡路线；静态 Ready/Disconnected 仍有持续 orbit/pulse，需要收敛为静态品牌或 Wayline。

## Shared / Web / tests

ESP32 和 Web/WASM 共用 moto_nav_ui.cpp、字体、NavPresenter、466×466 canvas。Web 另有 OSM fixture canvas overlay；它不是完整固件布局/性能证据。所有 shared 页面、文本、颜色、字体变更会同步影响 Web，geometry/坐标变换不动。

native nav_ui_render_tests 使用真实 headless LVGL RGB565 framebuffer，比较同状态可重复 hash、页面恢复、地图清空、容量、strip-height、motion settle 和 boot/power-off；没有固定 golden hash。nav_presenter_tests 断言字段/坐标/指针生命周期；phone bridge host tests 覆盖断线与恢复；协议 golden tests 独立。新 UI 字段需在 presenter/renderer 和测试 fixture 中同步，不改 packet。

## Hardware / fonts / performance

1.75C BSP 为 CO5300 + CST9217，466×466 RGB565，README/sdkconfig target 为32MB Flash与8MB octal PSRAM（未读取实体设备容量）；圆外像素物理不可见。设计基准 360 通过 px() 缩放到466，关键内容必须按圆形 chord 检查。320-row 双 PSRAM draw buffers，另 2MiB LVGL pool，64KiB internal heap。显示刷新/route motion 都25ms；IMU125Hz、呈现40Hz。预建四页与 bounded polyline slots，Tick 不销毁 object tree。

现有 Montserrat16/20/28/48；自定义 moto_font_nav_16 是小型中文子集，并非完整道路名字体。缺字需可见 fallback、UTF-8 边界安全截断。不会引入全量 CJK 或巨型数字包。Boot 现有1.25秒节奏保留。

## Visual reference

已阅读 assets/brand/waymate/README.md、waymate-mark.svg/生成几何、WaymateTheme 与 Stage B Audit/Report，查看 brand-preview.png、navigation-demo.png。W 为100×100上的两条等宽圆角路径；圆屏采用纯黑背景，White/Ice 主信息，Green连接、Amber过渡、Red错误，Graphite上下文。

## Planned rendering scope

集中重构 shared renderer：Boot W、静态 Ready/断线 Wayline、上方动作距离/中央真实地图/底部道路、明显 warning 与 Arrived、最大现有字体数字缩放、Compass明示DERIVED并在不可信低速隐藏方向、文字优先Media。仅必要的 NavPresenter 只读标志投影补齐 stale/off-route/has-next/heading display availability。禁止范围内业务/protocol/iOS/原design均不动；Stage4 production presentation wiring 留待以后。
