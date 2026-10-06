# Waymate · Stage A

Waymate 是「手机 + 车把圆形 AMOLED 屏幕组成的骑行智能路伴」。
一条路，一个同行者，一块始终陪伴骑行者的第二屏幕。
关键词：Way / Mate / Ride / Focus / Companion / Direction。

## 审计基线（2026-10-06，修改前）

- Assets.xcassets 有 AppIcon、AccentColor、LaunchBackground、LaunchLogo。
- AppIcon 是 1024×1024 山川/导航箭头渐变图，源图已画入圆角。
- Launch 通过 Info.plist 与 XcodeGen 的 UILaunchScreen 配置引用黑色背景和 LaunchLogo；无需新增启动业务代码。
- ContentView 使用分散的 blue/green/red/orange；未发现独立 Theme/Colors 定义。
- shared/nav_ui 已有本文所列八个基础色；此次仅阅读，未修改圆屏。
- ContentView 依赖 Dynamic Type、自适应布局、系统语义文字色、VoiceOver 标签与状态值、Reduce Motion；RouteOverviewMap 也读取 Reduce Motion。此次保留所有相关行为。
- 工作区原有未跟踪 design/；此目录未改动。

## Logo 与资产

两个相同的圆角路线单元并列组成 W，每个终点向上延伸，表达同行与前进。
100×100 坐标系、线宽 8、圆形端点与连接；禁止变宽、渐变、地图 pin。
24/32 px PNG 从矢量直接按最终尺寸渲染，无低分辨率放大。
图形和全小写字标可独立使用。字标为 Helvetica Neue Medium 的矢量轮廓，SVG 无字体运行依赖。

- `waymate-mark.svg`：透明底单色图形。
- `waymate-wordmark.svg`：独立字标。
- `waymate-lockup.svg`：图形 + 字标。
- `waymate-app-icon.svg`：1024 方形源，黑底浅色图形，未画入 iOS 圆角。
- `waymate-mark-{24,32,256}.png`：透明底导出。
- `brand-preview.png`：图标、字标、原尺寸 24/32 标志与色板审阅图。
- iOS AppIcon：1024×1024、不透明 sRGB PNG。
- iOS LaunchLogo：120 pt，1x/2x/3x 透明 PNG；原有纯黑 LaunchBackground 保留。

默认 SVG 使用 White；可统一修改根元素的 `color` 以制作黑色丝印版。
圆屏启动、BLE Connecting 和 README 可复用这些资产，本阶段未接入圆屏或连接流程。

## Tokens / Wayline

| 固定品牌色 | 色值 | 用途 |
| --- | --- | --- |
| Black | #050607 | 品牌背景 |
| White | #F3F4EF | 主信息/标志 |
| Ice | #B8EDF5 | 品牌强调 |
| Graphite | #303539 | 品牌表面 |
| Road | #42474B | 道路线条 |
| Green | #69D494 | Connected / Valid |
| Amber | #E6C84F | Warning / Transitional |
| Red | #FF4B43 | Error / Stop / Congestion |

SwiftUI 使用 `WaymateTheme`；固定品牌色与语义色分开。
`accent` 在 Light 为 #176575、Dark 为 Ice，与 AccentColor 资产一致。
Connected / Warning 在 Light 为 #216C42 / #766000，Dark 使用品牌色。
Error 在 Light 为 #B5241D、Dark 为 #FF766F：固定 Red 保留，深色语义变体提高 Graphite 表面上的文字对比度。
`onAccent` / `onError` 为按钮前景，Light 为 White、Dark 为 Black。
语义文字色在 White、系统浅色分组背景和 Black、Graphite、系统深色卡片上目标对比度至少 4.5:1。

`waylineStroke(width:)` 提供固定宽度、圆角端点与连接的 SwiftUI StrokeStyle。
`WaymateLogo(size:color:)` 提供可独立复用图形；默认放在品牌黑底。
页面继续使用系统 List/背景/语义文字色，不强制永久 Dark Mode。
本阶段只把 ContentView 显式强调/状态颜色接入 Tokens，保留布局、地图渲染、业务状态及所有生命周期。
不新增进度动画、连接策略或页面组件。

## 再生成

在仓库根目录运行：

```sh
swift scripts/ios/generate_waymate_brand.swift
xcodegen generate --spec platforms/ios/project.yml
```

生成器仅使用 macOS AppKit / CoreGraphics / CoreText，无新增依赖。
Logo 的 SwiftUI 坐标在 WaymateLogo.swift 中与生成器一致，修改图形时应同时更新。

## 验证结果（2026-10-06）

- XcodeGen 成功；最终版本 iPhoneOS 无签名 build 成功。
- Swift Package 核心测试：19/19 通过。使用 `/tmp/waymate-stage-a-core-tests` 构建缓存；外置盘上的重复慢速运行已停止。
- iOS App 单元测试：123/123 通过。
- 完整 UI 测试：16 项中 9 项通过、7 项失败，不能视为全套通过。
- Light、Dark、Accessibility XXXL 主页视觉测试通过，已检查截图。系统 List 与字号/滚动适配保持；截图在 `verification/home-*.png`。
- 两项地图测试在修改前 HEAD 的隔离副本中同样失败（WaymateUITests.swift:54/76，未找到 SearchField），确认是既有失败。
- 其余五项失败涉及在线目的地/路线搜索，未取得 `place-result-0`；本阶段未修改 provider、地图与导航逻辑，未将这些失败宣称为已排除回归。
- 对最终语义色进行 sRGB 对比度计算，文字/状态与指定表面、按钮前景组合均 >= 4.5:1。品牌 Red 与 Graphite 的组合不用于普通小字号文字；使用 error 语义变体。
- AppIcon 1024×1024、无 Alpha、sRGB；所有 Assets JSON 引用存在，1x/2x/3x Launch 图片尺寸正确。
- Simulator 已实际检查主屏幕 AppIcon 和系统 Launch：黑底 + 浅色 W，无附加文案/假进度。捕获 Launch 时仅临时让 Simulator 进程等待 debugger，未修改启动代码，之后结束该进程。
- 最终语义色调整只影响错误色与目的地图标色；主页视觉截图所覆盖的颜色与最终版本相同。额外重复视觉运行在执行前取消，不计入通过结果。
- `git diff --check` 通过。

完整 UI 失败项：

1. testLiveShanghaiCitySearchShowsDownloadCoverage
2. testMapDownloadsExposeCitySearchAndReturnHome
3. testNearbyDestinationCanBeSelectedAndReturnsToRecentSearches
4. testRoutePreviewSwipeRightReturnsToSearch
5. testRoutePreviewSystemBackReturnsToSearch
6. testRoutePreviewVisualState
7. testSelectedRouteStartsNavigationAndEndsAtHome

构建/测试日志与 xcresult 保存在 `/tmp/waymate-stage-a-*`，属于临时验证材料。
业务代码、ESP32、shared/nav_ui、页面结构及原有 design/ 未修改。
MapDownloadsView 和地图 renderer 的既有显式颜色留待后续阶段，不扩展本次页面修改范围。
