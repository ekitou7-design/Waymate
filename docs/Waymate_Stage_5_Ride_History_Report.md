# Waymate Stage 5 — Ride Summary + Local Ride History

日期：2026-10-07（Asia/Shanghai）。基线：`ce87adda37e7abd81431fa72cb7aed9d01eaf13d`。无 commit、无 push。

## Existing RideRecord

修改前 `RideRecord: Equatable, Sendable`，没有 Codable、ID 或名称：

```swift
let startedAt: Date
let endedAt: Date
let elapsedTime: TimeInterval
let movingTime: TimeInterval
let distance: Double
let maxSpeed: Double?
let track: [RideTrackPoint]
var averageSpeed: Double? { movingTime > 0 ? distance / movingTime : nil }
```

`elapsedTime` 沿用已有语义：排除显式暂停时间，包含静止时间。距离为米，速度为米/秒。

`RideTrackPoint: Equatable, Sendable` 原字段是 `latitude`、`longitude`、`timestamp: Date`、`horizontalAccuracy`、`speed: Double?`、`segment: Int`。坐标为实际 WGS84 观测；暂停、GPS 缺口已经由 recorder 分段。持续运动约每 2 秒采样，四小时约 7,201 点。

AppModel 原来仅在 `stopRide()` 中赋值 `lastRideRecord`，退出 App 即丢失。结束不改变 Navigation，UI 在当前屏幕恢复 START RIDE，显示最近一次记录已结束。

已有 `RouteOverviewMap` 使用 MapKit 绘制候选规划路线，输入和坐标转换属于路线预览。因此新增只接受实际 track 的独立地图，不复用规划路线接口。

## Persistence Choice

选择 Foundation Codable + Application Support JSON + 原子写入，使用 Swift actor 隔离文件读写、编解码和排序。文件位置为 App 沙箱中的：

```text
Application Support/Waymate/Rides/history-v1.json
```

`project.yml` 是项目生成源，最低 iOS 17.0，技术上可以使用 SwiftData。但本轮只需要记录增删改名与列表，JSON 更透明、可直接注入测试路径，避免新增数据库生命周期和框架依赖。

项目已有离线地图 pack/tile JSON 原子文件存储，也有专用于离线地图的 SQLite 索引；没有通用 Ride 数据库或 SwiftData 模型。本轮沿用 Foundation 文件存储方式。没有新增第三方依赖、账号、云同步或 iCloud 配置。Ride 目录设置 isExcludedFromBackup，排除系统备份，维持只在本机保存的要求。

## Stored Schema

顶层为 `RideStore.Document`：

```text
schemaVersion: 1
records: [RideRecord]
```

每条保存：

| 字段 | 保存内容 |
| --- | --- |
| id | UUID；生成一次，改名、重载保持不变 |
| name | 可选自定义名称；空白归一化为 nil |
| startedAt / endedAt | 绝对 Date，使用 Codable 原生 Date 编码 |
| elapsedTime / movingTime | 现有 recorder 的最终快照，秒 |
| distance | 现有 recorder 的实际累计距离，米 |
| maxSpeed | 可选最终速度快照，米/秒 |
| track | 全部既有轨迹点，保持原顺序 |

每个轨迹点完整保存 `latitude`、`longitude`、`timestamp`、`horizontalAccuracy`、可选 `speed`、`segment`。Date 使用 Foundation 默认编码，即相对 2001-01-01 reference date 的秒值；没有存格式化日期字符串。

`averageSpeed` 不重复序列化，仍由 `distance / movingTime` 推导；movingTime 为零时 nil，UI 显示 `--`。没有摘要折线替代原轨迹、压缩、重新采样或丢弃 Backtrack 所需字段。

## RideStore

`RideStore` 是不依赖 SwiftUI、BLE、Navigation 或 ESP32 的 actor，持有已加载 records，提供 `load`、幂等 `append`、`updateName`、按 UUID `delete`。AppModel 负责发布 UI 快照，所有历史操作按任务顺序执行，避免初始 load、连续 End、改名和删除互相覆盖。

- 文件不存在：返回空历史，不创建文件，不启动 Ride。
- 空文件、损坏 JSON、重复 ID 或未知 schemaVersion：返回错误，Store records 保持为空，OSLog 记录，History 显示读取失败。
- 同一实例保留 readError，拒绝后续写入；原文件原位保留，不静默覆盖，没有擅自丢弃/迁移损坏数据。
- 正常写入：先编码、创建目录、`Data.write(options: .atomic)` 替换文件，成功后才发布 Store records。
- 写入失败：原内存历史不变，AppModel 显示保存失败；有内存记录时可重试。损坏或未知 schema 文件仍受保护。
- 重复 append 同一 ID 不新增记录；改名或删除只操作目标 ID。

测试覆盖正常原子替换后的重载、编码失败后旧文件字节与 Store 内存不变、目录写入失败与恢复后重试。没有宣称已验证断电/文件系统故障中断时的耐久性。

## End Ride Flow

1. `stopRide()` 检查 live Ride，重复 END 直接返回。
2. `RideSession.stop()` 生成带新 UUID 的真实最终 Record；原 tracking 算法、flush、指标和分段均保持不变。
3. 停止 Ride 的位置订阅，保留 Navigation 的位置订阅，沿用原 presentation 更新。
4. 将 Record 交给串行持久化任务；UI 可以看到正在保存，Ride 生命周期已经结束。
5. 尝试 Store append。成功更新历史；失败记录明确错误，Record 仍由 session/任务及完成后的 lastRideRecord 持有。
6. 保存尝试结束后更新 `lastRideRecord`。最新结束 ID 防止较早完成结果覆盖较新的记录。
7. 满足自动呈现条件时显示 Summary。保存失败也能显示真实内存 Summary，带失败说明与重试入口。

快速连续结束两个 Ride，各自生成不同 ID、保存一次。若之后已开始新 Ride 或 Navigation，迟到的完成结果不会自动弹出 Summary。

## Navigation Interaction

END RIDE 继续独立于 END NAV。Navigation active 时结束 Ride 正常持久化，不停止 runtime 或共享定位，不自动弹出 Summary。当前导航屏保留“最近一次 Ride 已结束 · 查看记录”入口，由用户主动打开 Summary；关闭后仍在导航中。

同时检查“结束当时”和“保存完成时”的导航状态，防止异步写入完成后抢占新启动的导航。打开 History、Summary、Detail 本身没有 presentation 或 BLE 调用。

集成测试验证实际 Navigation runtime 保持 active、位置 source 未停止。UI 测试使用已有 Demo Navigation 验证导航屏不会被自动 Summary 抢占及主动查看后仍继续导航；不把 Demo 验证等同于真实在线路线验证。

## Summary

结束后展示共用 `RideDetailView(isSummary: true)`，标题 Ride Summary：

- 自定义名称，空名称按真实 startedAt 与系统 locale 生成日期名称。
- 系统 locale 日期/时间。
- Distance、明确区分的 Elapsed / Moving、Average / Max。
- 实际轨迹地图或 Route unavailable。
- 保存中、已保存、保存失败与重试状态。
- Edit Name 和永久删除确认；操作错误显示 alert。

使用既有 WaymateTheme 的背景、表面、accent、字体层级与系统可访问性，不重做整个 App UI。

## History

Idle / Home 的 secondary area 新增 `RIDES · 骑行记录`，采用 sheet 内 NavigationStack，没有传统 Tab Bar。

启动异步加载历史；显示 loading、empty、read-error 三种实际状态。列表按 startedAt 从新到旧排序，同时间用 UUID 作稳定排序。每条只显示名称、日期/时间、距离与明确标注的 Elapsed。

Debug-only UI 测试参数仅选择独立临时文件，不注入任何 RideRecord 或路线数据；重启使用同一个测试 UUID 可验证持久化，也不会清空用户历史。服务关闭的单元测试默认使用独立临时路径，支持显式注入 RideStore。

## Ride Detail

点击记录进入同一个 RideDetailView；通过稳定 UUID 查找真实已保存 Record，共用 Summary 的内容和操作。

改名使用系统 alert text field，去除首尾空白，空名称使用日期 fallback。只有 Store 写入成功才更新 UI 和匹配的 lastRideRecord。删除有取消/永久删除确认，只删目标记录，成功后返回历史列表；失败不会假装删除成功。重新启动仍反映改名和删除结果。

## Track Map

`RideRouteMap` 的唯一数据输入是 `[RideTrackPoint]`。`RideRouteGeometry` 按连续的 segment 边界分组，只绘制至少两个有效坐标的段；非法坐标会断开绘制。没有 Navigation route、provider polyline 或 fixture 路线输入。

每段一个 MapPolyline，地图根据可绘制实际轨迹点的联合 bounds 加 padding 自动 fit；禁止地图拖拽/缩放，保持外围 ScrollView 操作。没有足够连续点时显示 Route unavailable，不展示伪造路线。暂停与已有 GPS gap 的 segment 不会被连成跨缺口直线。

单位测试验证分段、空/单点/不同段单点无法成线，Codable 重载完整保留原始 track。UI 测试通过模拟器 Core Location 发出两次位置观测，现有 recorder 生成实际 Record，再验证 Summary 的 track map。该证据属于模拟器，不是户外真机 GPS。

## Storage Estimate

使用实际 RideRecord / RideTrackPoint 声明和 Swift JSONEncoder，对一个 7,201 点、四小时的合成估算样本进行编码；不向产品或历史文件注入该样本。无自定义名称，带 accuracy、speed、segment、timestamp 和变化坐标。

| 数量 | 估算 JSON 字节 | MB（十进制） | MiB |
| --- | ---: | ---: | ---: |
| 1 Ride | 802,054 | 0.80 | 0.76 |
| 10 Rides | 8,020,261 | 8.02 | 7.65 |
| 100 Rides | 80,202,331 | 80.20 | 76.49 |
| 500 Rides | 401,011,531 | 401.01 | 382.43 |

真实浮点精度、采样密度、暂停分段和名称会改变体积。当前单文档方案在 append/rename/delete 时重写全部历史，启动时解码全部轨迹；虽不阻塞主线程，数百次长 Ride 的文件和峰值内存成本仍大。后续应基于真机长期记录评估按 Ride 分文件/按需加载。此次没有实现压缩或改动轨迹数据。

## Changes

| 文件 | 修改内容 |
| --- | --- |
| platforms/ios/App/RideSession.swift | Record UUID/可选名称与 Codable；TrackPoint Codable |
| platforms/ios/App/RideStore.swift | 本地 JSON actor、版本和错误保护、原子写入 |
| platforms/ios/App/AppModel.swift | 启动加载、顺序保存、改名/删除/重试、Summary 请求 |
| platforms/ios/App/ContentView.swift | Home History 入口、Summary sheet、导航中查看入口与保存中状态 |
| platforms/ios/App/RideDetailView.swift | Summary/Detail 共用真实 Record 内容、格式与编辑操作 |
| platforms/ios/App/RideHistoryView.swift | 加载/空/错误状态、最新优先列表与详情入口 |
| platforms/ios/App/RideRouteMap.swift | 实际轨迹按 segment 绘图与 unavailable |
| platforms/ios/AppTests/RideStoreTests.swift | 7 个 Store/指标/轨迹测试 |
| platforms/ios/AppTests/RideHistoryIntegrationTests.swift | 6 个历史与 Ride/Navigation 集成测试 |
| platforms/ios/AppTests/RideProductionWiringTests.swift | 旧完成记录断言等待异步保存，不改变生命周期断言 |
| platforms/ios/AppTests/RideSessionTests.swift | 两次独立记录 ID 不同，仍比较确定性生命周期和指标 |
| platforms/ios/UITests/WaymateUITests.swift | 新增 4 个 Stage 5 UI 用例，更新原结束后 Summary 操作 |
| docs/Waymate_Stage_5_Ride_History_Report.md | 本报告 |

XcodeGen 重新生成成功；项目文件被仓库忽略，project.yml 没有变化。没有改动 design/。

## Tests

验证设备：iPhone 16 Pro Simulator，iOS 18.6。所有单元测试使用隔离目录；新增 UI 记录来自真实产品操作和模拟器 Core Location，没有预填充历史。

| 检查 | 最终结果 |
| --- | --- |
| 全部 iOS AppTests | 159/159 通过 |
| Ride 相关（含新增 Store/历史集成） | 60/60 通过 |
| Presentation Coordinator / production wiring | 34/34 通过 |
| Navigation ComponentState / Readout | 16/16 通过；其余相关 AppTests 包含在 159 项中 |
| Swift package tests | 19/19 通过 |
| Stage 5 相关 UI | 5/5 用例最终通过 |
| 既有 Demo Navigation UI | 2/2 通过 |
| 既有在线选路 UI | 0/1；HEAD 基线同样失败 |
| XcodeGen | 成功生成项目 |
| unsigned iPhoneOS build | 最终版本 BUILD SUCCEEDED，CODE_SIGNING_ALLOWED=NO |
| git diff --check | 通过 |

Stage 5 UI 用例覆盖：原 Start/Pause/Resume/End 的真实生产流程与 Summary、空历史、改名/重启/删除确认及持久化结果、经 Core Location 记录的实际地图、Navigation active 时结束保存/主动查看 Summary/继续导航。名称、指标、route-unavailable、actual-track、历史入口和编辑操作均有 accessibility identifiers。

新导航 UI 用例第一次运行时 END RIDE 控件位于底部系统手势区域，测试点击未打开确认框；修正测试滚动位置，并将 Demo 页面标题断言匹配“演示导航”，后续两次均通过。没有为此修改产品导航或结束行为。

在线 `testSelectedRouteStartsNavigationAndEndsAtHome` 首次运行在 `place-result-0.waitForExistence(timeout: 20)` 失败，尚未进入路线/Navigation/Ride 链路。用 `git archive HEAD` 创建独立基线、XcodeGen 和独立 DerivedData，在同一模拟器运行原用例，同样在等待第一条搜索结果时失败。测试保留，没有删除、跳过或用 fixture 替换。该结果证明这是本环境中基线也存在的在线搜索失败；尚未定位远端服务/网关/网络的具体根因。

最终备份排除属性加入后，全部 AppTests 再次 159/159、改名重启删除与导航继续两个关键 UI 用例再次 2/2；其余三个 Stage 5 UI 用例在最终保存顺序下均通过。Store 测试还验证目录 isExcludedFromBackup 为 true。

可复查日志与结果：

- `/tmp/waymate-stage5-validation.log`、`/tmp/waymate-stage5-validation.xcresult`：最终全部 AppTests + 两个关键 UI。
- `/tmp/waymate-stage5-ui-final.log`、`/tmp/waymate-stage5-ui-final.xcresult`：四个核心 UI 通过和第一次导航 UI 测试问题。
- `/tmp/waymate-stage5-nav-ui.log`、`/tmp/waymate-stage5-nav-ui.xcresult`：修正后的导航 UI 通过。
- `/tmp/waymate-stage5-ui.log`、`/tmp/waymate-stage5-ui.xcresult`：Demo UI 与在线搜索失败。
- `/tmp/waymate-stage5-baseline-search.log`、`/tmp/waymate-stage5-baseline-search.xcresult`：HEAD 基线在线搜索复现。
- `/tmp/waymate-stage5-swift.log`：Swift package 19/19。
- `/tmp/waymate-stage5-device-validation.log`：最终 unsigned iPhoneOS build。
- `/tmp/waymate-stage5-xcodegen-final.log`：项目生成。
- `/tmp/waymate-stage5-estimate.swift`：用实际模型和 JSONEncoder 计算存储估算。

已人工查看 Summary、空 History、改名后持久化 History 和实际轨迹地图截图；结果来自 XCTest 导出的 PNG。新地图用例与 Store 轨迹测试共同覆盖真实录制输入和 segment 绘制边界，不宣称已验证真机四小时 GPS、锁屏或长期累积性能。

## Architecture Check

| 检查 | 结果 |
| --- | --- |
| 修改 Ride Tracking 算法 | 否；只扩展 Record 的身份/编码/名称 |
| 修改 Navigation | 否；增加 AppModel Ride 完成后导航状态呈现保护 |
| 修改 PresentationCoordinator / policy / driver | 否 |
| 修改 BLE | 否 |
| 修改 ESP32 / 刷机 | 否 / 否 |
| planned route 冒充 actual track | 否；地图只接受 RideTrackPoint |
| 新增云/账号/iCloud | 否 |
| 压缩/重采样/丢失原始轨迹 | 否 |
| 自动恢复未结束 Ride | 否 |

## Remaining

- Share Card
- GPX
- Backtrack
- Active Ride crash recovery
- 真机长期记录验证

## Git Status

完整 `git status --untracked-files=normal` 输出：

```text
On branch main
Your branch is up to date with 'origin/main'.

Changes not staged for commit:
  (use "git add <file>..." to update what will be committed)
  (use "git restore <file>..." to discard changes in working directory)
	modified:   platforms/ios/App/AppModel.swift
	modified:   platforms/ios/App/ContentView.swift
	modified:   platforms/ios/App/RideSession.swift
	modified:   platforms/ios/AppTests/RideProductionWiringTests.swift
	modified:   platforms/ios/AppTests/RideSessionTests.swift
	modified:   platforms/ios/UITests/WaymateUITests.swift

Untracked files:
  (use "git add <file>..." to include in what will be committed)
	design/
	docs/Waymate_Stage_5_Ride_History_Report.md
	platforms/ios/App/RideDetailView.swift
	platforms/ios/App/RideHistoryView.swift
	platforms/ios/App/RideRouteMap.swift
	platforms/ios/App/RideStore.swift
	platforms/ios/AppTests/RideHistoryIntegrationTests.swift
	platforms/ios/AppTests/RideStoreTests.swift


It took 17.96 seconds to enumerate untracked files. 'status -uno'
may speed it up, but you have to be careful not to forget to add
new files yourself (see 'git help status').
no changes added to commit (use "git add" and/or "git commit -a")
```

`design/` 是进入本轮时已存在的未跟踪目录，未作修改。
