# Waymate Stage 6 — Ride Share Card + GPX Export

日期：2026-10-07（Asia/Shanghai）。HEAD：`ce87adda37e7abd81431fa72cb7aed9d01eaf13d`。本轮从已有 Stage 5 未提交工作区继续；未 commit、未 push、未修改 design/。

## Audit

- `RideRecord`：UUID、可选 name、startedAt、endedAt、elapsedTime、movingTime、distance、可选 maxSpeed、track。averageSpeed 仍按 distance / movingTime 推导，movingTime 为零时 nil。距离米、速度米/秒。
- `RideTrackPoint`：latitude、longitude、timestamp、horizontalAccuracy、可选 speed、segment。没有 altitude，本轮不扩展持久化 schema。
- `RideStore`：actor、本地 Application Support/history-v1.json、schemaVersion 1。导出只读取 Record，不写 Store。
- 没有独立 RideSummaryView：ContentView 的 Summary sheet 内 NavigationStack 和 History 的 NavigationLink 都使用 RideDetailView。新增动作只接入共用详情视图，History 列表保持原样。
- `RideRouteMap` 已按连续 segment 边界绘制 MapPolyline，非法坐标断开；可复用纯 RideRouteGeometry，不能复用规划路线预览接口。
- 现有品牌：WaymateLogo / WaymateMark、Black/White/Ice/Graphite、Wayline rounded stroke。使用固定品牌色，无渐变或新增视觉系统。
- 最低 iOS 17.0，支持 ImageRenderer。审计前没有 ImageRenderer、ShareLink 或 UIActivityViewController 封装。
- 原有 ride-summary、ride-detail、ride-detail-*、ride-edit-name、ride-delete-button 等 identifiers 保留；新增 ride-share-button、ride-export-gpx-button、ride-share-progress、ride-share-privacy、ride-gpx-unavailable。

## Share Card

固定 4:5，540×675 SwiftUI canvas，以 ImageRenderer scale 2 生成真正的 1080×1350 raster；不使用手机截图放大。导出固定 Dark / medium Dynamic Type，保持图片版式稳定；日期和名称 fallback 沿用用户系统格式。

内容：W Logo、waymate、真实 Ride 名称与开始日期/时间、actual track、Distance、Moving、Average、Max，以及克制的 Stay on your way.。数据全部从传入 RideRecord 读取。nil 平均/最高速度显示 `--`。名称最多两行，极长名称缩小并截断，记录本身不修改。空/单点/没有可绘制连续段时显示 Route unavailable，指标卡仍可分享。

以下为单元测试生成的合成 Record 卡片，仅用于布局 QA，未注入生产状态或 RideStore：

- [普通卡片](ui/stage6-share/test-normal-card.png)
- [长中文名称](ui/stage6-share/test-long-name-card.png)
- [无轨迹与 nil 速度](ui/stage6-share/test-unavailable-card.png)
- [7,200 点、四段轨迹](ui/stage6-share/test-7200-point-card.png)

已人工检查上述 PNG：文字、数据、路线与 footer 没有溢出。RideShareRenderer 只接受 Record，依赖 SwiftUI/UIKit；不依赖 BLE、AppModel 或 Navigation。ImageRenderer 返回 nil 或尺寸异常时抛出 Unable to create share image，UI 显示错误，不分享空白图片。

## Route Rendering

选择 B：直接绘制实际 GPS 坐标的极简 Wayline。方案 A（MapKit snapshot）可以加入地理底图，但底图加载会影响离线生成可靠性；本轮无需地名/底图，因此采用纯 geometry，不发在线地图请求。

先复用 RideRouteGeometry 按连续 segment / 非法点断开分组，再进行 spherical Mercator 投影：x = R × longitudeRadians，y = -R × asinh(tan(latitudeRadians))，R = 6,378,137 m。经度沿相邻观测解包，处理跨 ±180°日期线。投影只作用于图片，不修改原始 WGS84 点。

所有可绘制段取联合 bounds，x/y 使用同一个 scale、中心对齐，四边 24 canvas points padding，保持投影后的纵横比例。100 m 最小 viewport 防止极短/静止轨迹铺满整张图。Mercator 在极点不定义，遇到 ±90°会断开而非钳制/伪造坐标。

单个 Path，每段独立 move(to:)，从不跨 pause/GPS gap addLine。空心 Ice 起点和 White 终点来自首/末可绘制实际点，不推断地名。Mercator 保持局部形状，但并非等面积/等距离投影；没有宣称全球长距离地理尺度恒定。

## Share Flow

Summary / Detail → SHARE → RideShareRenderer → UIImage → iOS UIActivityViewController。

Summary / Detail → EXPORT GPX → 后台生成临时 .gpx → iOS UIActivityViewController。两项均为 secondary action，不在 History 行内新增按钮。准备中禁用重复操作，显示 progress；错误通过系统 alert 呈现。

系统渠道由 iOS 和已安装 extensions 提供；没有接入社交 SDK。项目源 project.yml 和生成 Info.plist 增加 NSPhotoLibraryAddUsageDescription，支持系统 Save Image 的权限说明。

## GPX

遵循 [GPX 1.1 官方 schema](https://www.topografix.com/GPX/1/1/)：namespace http://www.topografix.com/GPX/1/1，version 1.1，creator Waymate。metadata 包含 name、startedAt；trk 包含 name；每个连续记录 segment 对应 trkseg，每点 trkpt 包含真实 latitude/longitude 和 UTC ISO 8601 time（含毫秒）。保留单点段和原始点顺序，不重排、压缩或重新采样。

没有 ele、speed、extensions、用户账号或规划路线。XML 对五种特殊字符完整转义，Unicode 保留；XML 1.0 不支持的控制字符明确失败。xs:decimal 使用 Decimal 展开 Double 的 round-trip 表示，避免科学计数法或 locale 逗号。

空 track 明确失败并禁用 UI。无效坐标/时间不静默丢弃点，也不输出部分轨迹。GPX schema 的经度范围是 [-180, 180)，精确 +180 会失败，避免私自修改记录坐标。

文件名使用开始日期的 UTC 日期：Waymate-YYYY-MM-DD-Ride.gpx，不插入用户名称，因此中文名称不会失败，斜杠、冒号、目录穿越或控制字符无法进入路径；Ride 名称完整保留在 XML 中。

临时文件位于 tmp/WaymateRideExports/随机UUID/，分享关闭后删除本次目录，写入失败也清理；下次导出清理超过一天的崩溃遗留。只删除自身导出根目录下的文件，不在 Documents 重复保存。

## Coordinate Integrity

已追踪 CoreLocationNavigationSource → SharedLocationSource → RideSession.accept / append：CLLocation 经纬度进入 WGS84Point，SharedLocationSource 将同一观测交给 Ride，RideRecord 直接保存 fix.coordinate。此链路没有 GCJ-02 转换或 route matching；provider 坐标转换属于独立 Navigation 路径。

GPX 直接读取持久化 WGS84 latitude/longitude，未修改 provider、坐标转换、已有记录或 GPS filtering。系统 XMLParser 测试逐点比较输出和 Record；7,200 点样本另通过官方 XSD 验证。

## Privacy

两个动作下方始终可见简短提示：“共享内容包含实际骑行轨迹。”。没有每次确认弹窗、自动隐私区、账户或隐私系统。

## Performance

轨迹投影、联合 bounds 与 Path 都为线性遍历；不创建数千个 SwiftUI child Views。GPX 预分配 Data 容量，逐点追加 UTF-8，后台 detached task 编码/写文件，不做整个字符串反复复制。

iPhone 16 Pro / iOS 18.6 Simulator 的合成 7,200 点样本：四段，每段 1,800 点；GPX 561,151 bytes，导出约 0.025 秒；投影 + ImageRenderer + PNG 编码约 0.032 秒。数值只说明此次模拟器样本，未测量真机长期记录的峰值内存或耗电。

## Changes

本轮新增/修改文件：

| 文件 | 本轮内容 |
| --- | --- |
| platforms/ios/App/RideShareCardView.swift | 纯轨迹投影、Path、品牌卡片、ImageRenderer |
| platforms/ios/App/RideGPXExporter.swift | GPX 编码、验证、文件名、临时文件与清理 |
| platforms/ios/App/RideShareActions.swift | 共用 secondary actions、系统分享、进度与错误 |
| platforms/ios/App/RideDetailView.swift | 接入共用输出动作，一行接线 |
| platforms/ios/project.yml | 相册保存权限说明源 |
| platforms/ios/App/Info.plist | XcodeGen 生成的权限说明 |
| platforms/ios/AppTests/RideExportTests.swift | 10 个 Share/投影测试与 8 个 GPX 测试 |
| platforms/ios/UITests/WaymateUITests.swift | 新增输出 UI 流程测试 |
| docs/ui/stage6-share/*.png | test-normal-card、test-long-name-card、test-unavailable-card、test-7200-point-card、simulator-image-share-sheet、simulator-gpx-share-sheet、simulator-detail-image-share-sheet、simulator-detail-gpx-share-sheet（均为 .png） |
| docs/Waymate_Stage_6_Ride_Export_Report.md | 本报告 |

进入本轮已存在的 Stage 5 AppModel、ContentView、RideSession、RideStore、历史视图和旧测试改动予以保留。与本轮入口 diff 比较，AppModel、ContentView、RideSession、RideProductionWiringTests、RideSessionTests 无新增改动。

## Tests

验证设备：iPhone 16 Pro Simulator，iOS 18.6。测试记录使用隔离 Store；UI 测试通过真实产品 START/END 和模拟器 Core Location 形成 Record，没有预填充生产历史。

| 检查 | 最终结果 |
| --- | --- |
| 全部 iOS AppTests | 177/177 通过，最终代码再次通过 |
| Stage 5 RideStore | 7/7 通过，含重载、分段、失败保护 |
| Ride Tracking | 23/23 通过 |
| Share renderer / projection | 10/10 通过，覆盖所要求的 15 类情况 |
| GPX | 8/8 通过，覆盖所要求的 12 类情况，含系统 XMLParser |
| Swift package | 19/19 通过 |
| Stage 5 相关 UI | 5/5 通过 |
| 新增输出 UI | 2/2 通过；分别覆盖 Summary 与 Detail，共四条输出流程 |
| 既有在线选路 UI | 0/1；HEAD 基线比较见下文 |
| 官方 GPX 1.1 XSD | 7,200 点输出通过 xmllint schema 验证 |
| XcodeGen | 成功 |
| unsigned iPhoneOS build | 最终 BUILD SUCCEEDED，CODE_SIGNING_ALLOWED=NO |
| git diff --check | 通过 |

Share 测试包含 normal、nil Average/Max、empty track、单段/多段、极短/静止、长路线、横/纵 bounds、Unicode/长名称、非空 PNG、1080×1350 和 scale、Path move/line 数量证明不跨段连接；额外覆盖日期线、非法点与极点。

GPX 测试解析 namespace/version/creator、坐标、时间、单点段、pause/GPS gap、特殊字符与 Unicode、文件名、空/非法输入、确定性字节与排序、7,200 点完整保存，以及临时文件清理范围。没有通过 string contains 代替 XMLParser；官方 XSD 是额外独立 schema 验证。

首次新增 UI 验证失败来自查询系统根 view 的自定义 identifier，实际可访问性树为 ActivityListView；随后 History 查询误匹配了底层 ride-history-button。修正为系统标识与 UUID 行标识后，两项均通过，未改动历史/导航行为。已人工检查系统分享截图，图片面板提供 Save Image，GPX 面板提供存储到“文件”。没有实际向微信、AirDrop 或他人发送内容，也没有将模拟器证据当作真机/第三方 extension 验证。

[Summary 图片分享](ui/stage6-share/simulator-image-share-sheet.png)、[Detail 图片分享](ui/stage6-share/simulator-detail-image-share-sheet.png)、[Summary GPX 分享](ui/stage6-share/simulator-gpx-share-sheet.png)、[Detail GPX 分享](ui/stage6-share/simulator-detail-gpx-share-sheet.png)。

分享关闭后只读检查模拟器导出目录：最终成功用例的 Summary/Detail 临时 GPX 均已删除；剩余一份来自早期失败测试终止 App 的导出，按一天 TTL 留待后续自动清理，符合崩溃遗留策略。

在线用例 testSelectedRouteStartsNavigationAndEndsAtHome 在等待 place-result-0 时失败，未进入路线/Navigation/Ride 输出链路。HEAD 基线使用先前 git archive HEAD 的隔离目录与既有构建，并逐字核对 AppModel、ContentView、UITests 文件等于当前 HEAD；同一模拟器本轮复跑结果：同样在等待 place-result-0 时失败（1/1 失败）。两者不归因于 Stage 6；尚未定位在线搜索服务/网关/网络的具体根因。

日志与结果：

- /tmp/waymate-stage6-validation.log、.xcresult：最终 177 AppTests + 2 输出 UI。
- /tmp/waymate-stage6-ui.log、.xcresult：Stage 5 五项回归通过、在线失败及早期输出查询问题。
- /tmp/waymate-stage6-baseline-online.log、.xcresult：本轮 HEAD 在线基线比较。
- /tmp/waymate-stage6-unit.log、.xcresult：首次 177 AppTests 和性能附件。
- /tmp/waymate-stage6-swift.log：Swift package 19/19。
- /tmp/waymate-stage6-device-final.log：最终 unsigned iPhoneOS build。
- /tmp/waymate-stage6-xcodegen.log：项目生成。
- /tmp/waymate-stage6-gpx.xsd、/tmp/waymate-stage6-unit-attachments/2B641B0C-0D8F-4108-A2EC-602E49B36089.xml：官方 XSD 与通过验证的 7,200 点样本。

初次沙箱内 XcodeGen 无权写生成 Info.plist，CoreSimulator 不可访问；在授权的工具权限提升后生成、构建和测试完成。不是产品代码失败。

## Architecture Check

| 检查 | 结果 |
| --- | --- |
| Ride Tracking / GPS filtering / moving time / average 定义 | 本轮未修改 |
| RideStore schema / 持久化坐标 | 未修改 |
| Navigation / provider / NavCore | 未修改 |
| PresentationCoordinator | 未修改 |
| BLE | 未修改 |
| ESP32 / Round Display UI | 未修改 |
| planned route 冒充 actual track | 没有；输出唯一输入为 Record.track |
| design/ | 未修改 |
| commit / push | 均未执行 |

## Remaining

- Backtrack
- Active Ride crash recovery
- Notifications feasibility
- 真机长期 Ride 测试

## Git Status

完整 `git status --untracked-files=normal`：

```text
On branch main
Your branch is up to date with 'origin/main'.

Changes not staged for commit:
  (use "git add <file>..." to update what will be committed)
  (use "git restore <file>..." to discard changes in working directory)
	modified:   platforms/ios/App/AppModel.swift
	modified:   platforms/ios/App/ContentView.swift
	modified:   platforms/ios/App/Info.plist
	modified:   platforms/ios/App/RideSession.swift
	modified:   platforms/ios/AppTests/RideProductionWiringTests.swift
	modified:   platforms/ios/AppTests/RideSessionTests.swift
	modified:   platforms/ios/UITests/WaymateUITests.swift
	modified:   platforms/ios/project.yml

Untracked files:
  (use "git add <file>..." to include in what will be committed)
	design/
	docs/Waymate_Stage_5_Ride_History_Report.md
	docs/Waymate_Stage_6_Ride_Export_Report.md
	docs/ui/stage6-share/
	platforms/ios/App/RideDetailView.swift
	platforms/ios/App/RideGPXExporter.swift
	platforms/ios/App/RideHistoryView.swift
	platforms/ios/App/RideRouteMap.swift
	platforms/ios/App/RideShareActions.swift
	platforms/ios/App/RideShareCardView.swift
	platforms/ios/App/RideStore.swift
	platforms/ios/AppTests/RideExportTests.swift
	platforms/ios/AppTests/RideHistoryIntegrationTests.swift
	platforms/ios/AppTests/RideStoreTests.swift

no changes added to commit (use "git add" and/or "git commit -a")
```

该输出包含进入本轮前已有的 Stage 5 改动与 design/；本轮未修改 design/。
