# Waymate Stage 7 — Backtrack / 原路返回 V1

日期：2026-10-07（Asia/Shanghai）。基线 HEAD：`9ab28327ec5d0ee6f31a088ff418a091264fe977`。

实现了当前 active Ride → 固定实际轨迹快照 → 本地反向 breadcrumb guidance → Ride 起点的 iPhone 主流程。Round Display Backtrack **Not wired**，BLE v1 保持不变。本轮未 commit、未 push，未修改 design/。

## Architecture Audit

修改前审计记录见 [Backtrack Audit](Waymate_Stage_7_Backtrack_Audit.md)。核心结论和当前生产 ownership：

| 对象 | 唯一 owner / 来源 | 本轮接线 |
| --- | --- | --- |
| Current Ride track、采样、距离、movingTime | AppModel 内 private RideSession | 只读，不改采样或统计 |
| Completed RideRecord | RideSession.stop 的真实输出 | 完整保存 outward + return |
| Local history | RideStore actor，schema v1 | 不修改 |
| 普通 Navigation | SharedNavigationRuntime → C++ NavApp/NavCore | 仅启动边界增加冲突确认，算法不改 |
| Backtrack | AppModel 内 BacktrackSession | 独立 Swift guidance，不进入 NavCore |
| 连续位置源 | CoreLocationNavigationSource → SharedLocationSource | 在已有 Ride callback 读取同一 NavigationFix |
| Page policy / manual / Media | PresentationCoordinator / PresentationDriver | 新增 backtrack primary，复用既有事件与 expiry |
| BLE cache / reconnect | ESP32BLECentral | 原机制原样保留；只发送现有真实 Navigation snapshot 与既有 page |
| Round render | PhoneNavBridge → NavPresenter → nav_ui | 没有 Backtrack 消费者，没有修改 |

CoreLocationNavigationSource 保留一个连续 CLLocationManager。已有 SearchLocationBiasSource 的 one-shot manager 用于搜索，不是本轮新增，也不参与 Backtrack。Backtrack 不 start/stop manager，不增加订阅；Ride active 提供持续位置，paused 释放 Ride 订阅，普通 Navigation 如仍订阅可继续。Backtrack 与普通 Navigation 的互斥在 AppModel live/demo 启动边界实施。

## Backtrack Product Model

Backtrack 只针对当前正在记录的 Ride，默认唯一目标是其首个实际有效 GPS 点（Ride Start）。没有定位前按下 Start Ride 的物理位置无法凭空还原，首个有效 recorded fix 是可证实起点。

入口要求：至少 3 个有效 recorded points，至少 50m 段内实际 breadcrumb 长度，且存在距首点至少 20m 的点。对应原 recorder 的至少 2 秒/3m 采样，避免两个点或长时间小范围抖动就启用。Ready 由实际观测计算，未满足显示 Not enough ride history yet；paused 显示 Resume Ride to start Backtrack。

它不是 provider 回起点路线、道路 turn-by-turn 或 ETA。没有任意 prior point、History Backtrack、GPX import，也没有制造 maneuver、road name 或 traffic。

## Backtrack Route

`BacktrackRoute.build` 只接收 RideTrackPoint 和真实 Ride.startedAt。Active Ride 当前没有 UUID（Record 的 UUID 在 stop 时生成），因此 sourceRideStartedAt 表达当前来源；每次 Backtrack snapshot 自己有独立 UUID，不冒充 persisted Ride ID。

构建先保留连续 recorded runs，再逆序 runs 和每段内 points。Snapshot 内只有实际 WGS84 坐标和累计段内距离，字段不可变；factory 保证有效起终点、非空段和最低轨迹条件。中间非法点断开，不跨过连接；非法首/末点拒绝启动。

返程新增点只进入 RideSession，不进入 snapshot。重复 Start 不替换 snapshot 或进度；End Backtrack 后可再次从当前完整实际 Ride 启动一个新快照。

## Segment Handling

原 recorder 在 Pause/Resume、超过 15 秒 GPS outage 和 stationary/motion 边界断 segment。本轮全部尊重，包括 singleton；不 flatten 后构造一条线。

每段预计算 cumulative distance 和在整条 breadcrumb 中的 offset。Gap 的空间距离不计入 total/remaining。反向走完当前段后进入 TRAIL GAP，明确指向下一真实段的入口端点；前视目标也不跨 gap。接近下一 endpoint（定位精度 ≤20m、端点距离 ≤15m）才进入下一段，一次更新至多跨一段。大断点同样处理，不提供虚构通行线。

地图每个段独立 MapPolyline，gap 无连线，下一段入口显示断点标记。当前目标在 gap 对面时只是方向目标，不表示该空间已记录或可通行。

## Progress Algorithm

纯 Swift `BacktrackSession.update`，无平台 callback、route provider 或磁盘副作用：

1. 验证 WGS84、accuracy、timestamp；拒绝过期/未来、乱序或重复观测。Freshness task 每秒标记 >15s 的位置过期，没有新位置时也会隐藏指导。
2. 不合理位移超过 max(60m, speed × min(dt,15s) × 2 + 前后 accuracy) 时标记 LOCATION JUMP，不推进。速度仅接受有限的 0–60m/s 值作为 envelope。
3. 当前段按累计距离二分定位当前 edge，搜索前方最多 48 条边、身后最多 4 条边。前进空间预算 min(60m, max(8m, displacement × 1.5 + 3m))，不做全局最近点。超出窗口的 edge projection 截到该真实 edge 的合格范围，保持前进上限；稀疏采样不会因为投影稍越窗口而丢掉整条 edge。
4. 对短 recorded edge 用本地 tangent-plane projection，实际距离以 WGS84 观测坐标做球面近似计算。日期线经度差解包；这不是道路匹配或椭球测地引擎。
5. 前方同样接近时优先前方合格位置；前方候选距离差不足 2m 时保持较早候选。身后点可作附近接回参考，不使进度后退，也不压过等距的前方重叠腿。完整 U-turn 测试验证可沿同一路返程。
6. 只有 accuracy ≤20m、距附近实际段 ≤20m、非 offTrack，并且前进超过 3m 才更新进度。segmentDistance 总体单调，切段时 offset 保证全局进度单调。

交叉、loop、U-turn 和完整密集交叉穿越都有测试。窗口外的远处路线不会被自动捕获；偏离后需接回当前附近可解释的轨迹。这是 V1 有意的保守选择，避免跨交叉点跳过大量实际路程。

## Guidance

正常 target：从 matched progress 沿当前段前视 30m，段末截断。OffTrack target：当前局部窗口内最近合格的实际 breadcrumb projection/retained point。Gap target：下一真实 segment endpoint。

- remaining：实际 polyline 剩余长度，不含 gap，不是当前位置到起点直线距离。
- distanceToTarget：当前位置到指导 target 的距离，独立展示。
- bearing：WGS84 当前位置 → target 的绝对方位；不当成 heading。
- relativeDirection：仅 course 在 [0,360)、speed 2–60m/s、accuracy ≤20m 时用 bearing − course；其余显示“北为上”的绝对方位。未使用手机 CLHeading 或圆屏 IMU 伪装精确罗盘。
- offTrack：偏离距离 > max(25m, 2 × accuracy)，已 offTrack 时回到该阈值 70% 内才解除，避免边缘抖动。accuracy >20m 显示 GPS ACCURACY LOW，冻结进度、隐藏指导且不产生 urgent override；>50m 直接拒绝指导。
- 新进入 offTrack 产生 route UUID + transition counter 的事件身份，重复更新身份不变，接回后再次偏离才是新事件。
- Arrival：只有最终 segment 剩余 ≤10m、accuracy ≤20m、位置进入起点 max(10m,min(15m,accuracy)) 半径才 START REACHED。途中过起点附近不能提前到达。Arrival 保持到用户 End Backtrack；Ride 继续记录。

没有 REROUTING，不请求 AMap/其他 provider，不估计 ETA。

## Lifecycle

- Start Backtrack：仅 active Ride + 足够实际轨迹；复用当前 Ride，无第二 Ride。
- 普通 Navigation active：先提出“开始原路返回将结束当前导航。”；取消保留旧 Navigation，确认才 End Navigation → Start Backtrack。确认时若 Ride 已 paused，不结束旧 Navigation。
- Backtrack active → Start Navigation：live 和既有 Demo 启动边界均提出“开始普通导航将结束原路返回。”；取消保留 Backtrack，确认才切换。目的地/预览的现有有效性检查仍执行。
- Pause：Backtrack session/snapshot 保留，指导隐藏，不偷偷 resume。Resume：通过原 Ride 订阅恢复，等待新 fix。
- End Backtrack：只清指导，不 stopRide、不保存/修改 Record。
- End Ride：取消待确认切换、结束 Backtrack，然后走原保存链。原 Navigation 与 End Ride 的独立关系不变。
- App crash 不恢复 Backtrack，本轮不扩 active Ride crash recovery。

## iPhone UI

Ride section 的 BACKTRACK 为 secondary action，未满足条件禁用并显示原因；Home、正在普通导航的 Ride section、预览中的 Ride section共用真实入口。原 accessibility identifiers 保留。

新增独立 BacktrackView：BACKTRACK / FOLLOW TRAIL / OFF TRACK / TRAIL GAP / START REACHED、方向箭头、target 距离、RETURN TO START、剩余 actual trail、固定快照地图、当前定位与 Ride Start。剩余 Ice、已回溯 Graphite，当前段完成 overlay 截止到实际 matched position，所有 gap 分开。

暂停/恢复、End Ride、End Backtrack 和选择目的地均可操作。选择目的地只切到搜索呈现，Backtrack 仍 active；可 RETURN TO BACKTRACK，真正 Start Navigation 才要求模式替换。系统 Back 与现有 Navigation 一致，结束当前 guidance，保留 Ride。

页面明确告知圆屏暂不显示原路返回指导。没有修改品牌、字体或已有 Stage C 系统。截图来自 XCTest 位置进入真实 Core Location recorder，不是生产 fake GPS；人工检查内容、地图和偏离提示。

最终通过用例的截图：[Backtrack](ui/stage7-backtrack/simulator-backtrack.png)、[Off Track](ui/stage7-backtrack/simulator-off-track.png)、[Navigation → Backtrack 确认](ui/stage7-backtrack/simulator-nav-to-backtrack.png)、[Backtrack → Navigation 确认](ui/stage7-backtrack/simulator-backtrack-to-nav.png)、[History 无入口](ui/stage7-backtrack/simulator-history-no-backtrack.png)。

## PresentationCoordinator

增加独立 `PrimaryComponent.backtrack`、backtrack input 和 Home/OffTrack/Arrived reasons，不向 NavigationComponentState 加字段。

正常 Backtrack 可被既有 5s Media 临时交互覆盖，expiry 重新 evaluate 回 Backtrack。有效的新 offTrack 事件可打断 Media，并通过 Driver 恢复 Home fallback。普通点更新不重新选页，重复 offTrack identity 不抢回；用户手动 Compass/Music 浏览沿用原逻辑。Paused/stale/poor fix 不产生 urgent event。没有新增 temporary system。

## Round Display

**Backtrack guidance Not wired。** 当前固件没有 Backtrack page/模式/箭头/remaining/breadcrumb progress 消费者。本轮不宣称 Round Display 完整 V1，也不宣称硬件 reconnect 已通过。

AppModel 的 coordinator decision 是 Backtrack；Driver 为 BLE v1 明确映射现有 Speed fallback。它只是兼容页面选择，不是 Backtrack Home，不传 Backtrack geometry/progress，不补造 NavCore snapshot；现有 Speed 数据能力没有在本轮扩展。用户仍可手动浏览已有页面。

测试证明：本地 route/progress 在 driver resync 前后不变，expired Media 不恢复，decision 仍 Backtrack，发送的 fallback 是 Speed。BLE 收到 Ready 后仍只重发最新现有状态，不 Start Backtrack、不重播 command。圆屏恢复 Backtrack route/progress **未实现**。

## BLE

未修改 schema、packet layout、codec、ESP32 adapter、PhoneNavBridge、NavPresenter、shared/nav_ui 或字体。

审计原因：DisplayPage 只有四值；NavigationSnapshot 的 phase/maneuver/road/remainingDuration 语义属于普通导航；RouteGeometry 是带 token/generation 的单条连续 24 点局部线，无 gap 或 source；MapScene spans 是道路背景，不能把 breadcrumb 冒充道路。要干净支持 Round Backtrack，需要之后审核独立 additive Backtrack presentation contract 和 renderer 子阶段；没有将此扩展塞入本轮。

## Location Ownership

没有新增第二个连续 CLLocationManager。一个既有连续源 → Ride Recording → Backtrack Guidance。BacktrackSession 在 AppModel，SwiftUI 只持有视图呈现状态。ESP32 不拥有业务 progress。

## Performance

构建 O(n)，预计算每段 cumulative/offset；每次指导更新 O(log n + k)，k ≤53 条边，不搜索全部 7k 点。Ready 先按新追加的几个点更新空间展开缓存；达到统计距离/点数/展开条件才完整验证一次，ready 后不反复重建 route。Start 再验证并固定快照。

7,200 点、单段、每点 5m 的 iPhone 16 Pro / iOS 18.6 Simulator 合成路线：最终构建 2.981ms，1,000 次连续更新 5.143ms，约 5.1µs/update；是此样本的模拟器时间，不是硬件指标。地图 overlay 的构建/MapKit 绘制是 O(n) 呈现成本，与 matching 分开；没有声称测试了真机 7k 点地图帧率、锁屏耗电或数小时运行。Snapshot 只保留一份不可变 geometry，Published 更新通过 Swift array COW 共享，不形成另一个可变 Ride track。

## Tests

修改前全部 AppTests 177/177。最终代码新增 49 项 Backtrack 测试，全部 AppTests 226/226（包含 Ride Tracking 23、RideSession 13、Ride production 11、RideStore 7、History integration 6、GPX 8、Share 10、既有 Coordinator 14、Presentation production 20、Navigation component 13、Navigation readout 3；其余 BLE/map regression 同时运行）。Swift package 19/19。

最终 XcodeGen 成功，unsigned iPhoneOS BUILD SUCCEEDED，CODE_SIGNING_ALLOWED=NO。shared renderer/ESP32 未修改，native/C++ 和 ESP-IDF build 不适用，本轮未运行/刷机。git diff --check 通过。

Stage 5/6 七项相关 UI 回归 7/7：Ride lifecycle、录制地图、Navigation 中结束 Ride/继续 Navigation、空 History、改名重启确认删除、Summary/Detail Share、实际 GPS GPX 分享。Backtrack UI 三项最终 3/3，包含两个模式确认、实际 track 和 OffTrack/rejoin、End 后 Ride continues、History 无入口。该冲突 UI 使用既有 Demo Navigation；live Navigation 的生产启动边界另有单元测试，不能据此声称在线 provider 导航闭环通过。

| 检查 | 结果 |
| --- | --- |
| Backtrack pure route/progress/readout | 34/34 |
| Backtrack lifecycle + presentation | 15/15 |
| 全部 iOS AppTests | 226/226 |
| Swift package | 19/19 |
| Stage 5/6 相关 UI | 7/7 |
| Backtrack UI | 3/3 |
| 在线导航 UI / 当前 HEAD 基线 | 0/1 / 0/1；同一搜索结果等待失败 |
| XcodeGen / unsigned iPhoneOS | 成功 / BUILD SUCCEEDED |
| git diff --check | 通过 |

首次新单元测试的两项失败是插值 Double 精度严格相等和未排序 JSON bytes；改用地理距离容差和 sortedKeys，保留原数据不变的断言。补查完整 U-turn 时修正重叠路径身后点压过前方点造成卡住的算法问题，并用整条 U-turn 和 dense crossing 回程验证。最终补测稀疏真实 edge 的搜索窗口截断，确认不误报 offTrack，且进度仍受 60m 上限约束。

首次 UI 已通过 Start/OffTrack/Rejoin/End 的主体操作，后续 History 行查询误匹配背景 Home 按钮；模式切换用例第二次点击已展开的“更多”导致折叠。修正为 sheet 内列表按钮及按实际展开状态操作，没有删除测试或用生产 fixture 掩盖失败。

在线 `testSelectedRouteStartsNavigationAndEndsAtHome` 当前实现在 WaymateUITests.swift:390 的 `place-result-0.waitForExistence(timeout:20)` 失败，尚未进入 preview/Start Navigation/Backtrack。使用 `git archive HEAD` 的独立 /tmp/waymate-stage7-head 与独立 DerivedData，本轮核对 AppModel、ContentView、UITests、project.yml 文件逐字等于当前 HEAD；同一模拟器复跑原用例，也在同一行等待第一条搜索结果失败。不是 Stage 7 新增路径的回归证据，远端服务/网关/网络的具体根因尚未定位。

HEAD 在线调用最初被自动审批认为可能发送未授权定位而拒绝；只读核对证明 XCTest setUp 使用仓库固定济南 Demo 坐标及固定“奥体中心”查询，并说明用户已明确要求 HEAD 比较后，同一调用获准执行。没有改变测试、用间接方式绕过拒绝或发送用户真实位置。

日志/结果：

- /tmp/waymate-stage7-baseline-unit.log / .xcresult：修改前 177 AppTests。
- /tmp/waymate-stage7-completed.log / .xcresult：最终 226 AppTests + Backtrack UI 3/3，性能附件。
- /tmp/waymate-stage7-regression.log / .xcresult：Stage 5/6 UI 7/7、在线搜索失败及修正前新 UI 查询问题。
- /tmp/waymate-stage7-head-online.log / .xcresult：本轮当前 HEAD 在线比较。
- /tmp/waymate-stage7-swift.log：Swift package 19/19。
- /tmp/waymate-stage7-xcodegen-final.log：最终工程生成。
- /tmp/waymate-stage7-device-completed.log：最终 unsigned iPhoneOS build。
- /tmp/waymate-stage7-completed-attachments/：最终通过截图和性能附件；报告图片已复制到 docs/ui/stage7-backtrack/。

初次沙箱读取模拟器服务受权限限制，使用已授权的工具提升后运行；不是产品失败。没有真机定位、长期后台、耗电或实际圆屏指导通过结论。


覆盖请求的 51 类场景（合并成有意义的测试，未删除原测试）：

| 请求项 | 对应测试覆盖 |
| --- | --- |
| 1–3 empty/one/insufficient | EmptyTrack、SinglePoint、TwoFarPoints、InsufficientDistance、JitterExtent |
| 4–8 single/multiple/reverse/gaps | SingleSegmentReverses、SegmentsReverse、SingletonAndRepeatedIDs、InvalidMiddlePoint |
| 9–10 immutable/fixed snapshot | OriginalRecordAndSnapshot、SnapshotFixedWhileReturnRideContinuesAndFullRecordPersists |
| 11–15 endpoint/move/monotonic/jitter/behind | StartsAtOutwardEndpoint、MovesTowardStart、MonotonicJitterAndNearestPointBehind |
| 16–19 cross/loop/U-turn/jump | SelfIntersectingRoute、DenseCrossingFullReverse、LoopNearStart、UTurnFullTraversal、LargeGPSJump |
| 20–22 accuracy/segment/gap | PoorAccuracy、SegmentAndGapTransition、LookaheadNeverCrossesGap |
| 23–25 remaining/lookahead/bearing | RemainingTrailNotStraightDistance、StartsAtEndpoint、CourseIsNotBearing |
| 26–31 on/slight/off/poor/rejoin/event | SlightDeviationAndHysteresis、PoorAccuracyRaisesThreshold、OffTrackEventIdentity |
| 32–34 early/final/ride | LoopNearStart、FinalArrivalSticky、FullRecordPersistsAndRideContinues |
| 35–40 start/end/repeated/inactive/paused | StartRepeatedStartEndRepeatedEnd、InactiveInsufficientPaused、PausedBacktrack |
| 41–42 navigation conflicts | NavigationConflictCancel/Confirm、PauseWhileConfirmation、StartLiveNavigationRequiresConfirmation、DemoAlsoRequiresConfirmation |
| 43–45 Media/expiry/end independence | MediaExpiryReevaluatesBacktrack、EndKeepsSingleRideAndSource |
| 46–49 Home/manual/urgent/repeat | IndependentPrimaryWithExplicitFallback、ManualCompassStaysAndNewOffTrackReclaimsOnce |
| 50–51 reconnect/expired Media | ReconnectKeepsLocalRouteAndProgressRestoresFallback；仅本地和现有 fallback，不等同圆屏 guidance reconnect |

UI 三项覆盖：不足/暂停禁用；真实录制 → Start → OffTrack XCTest 位置 → Rejoin → End → Ride continues → 保存/History 无入口；两个模式切换确认。历史、Share/GPX、Navigation regressions 使用原测试。没有添加 production fake GPS。

## Real-device Test Plan

2026-10-07 晚间，iPhone + 现有圆屏统一测试；现在没有真机通过结论。

1. Stage 4：连接圆屏，Ride/Navigation/Media 切换；手动 Compass 后普通点更新不抢页，Media 到期回当前 Home；断开重连确认最新状态、无指令重播。
2. Stage 5：Start Ride，户外行走/骑行，Pause/Resume，End；检查 Summary 指标、实际 track 与 gap，History 关闭重开/重启后仍在，名称修改。
3. Stage 6：Summary 和 History Detail 分享图片到系统预览；GPX 保存文件，核对坐标/UTC time/segment；不需要向他人发送。
4. Stage 7：新 Start Ride，实际走一个至少 100m、有两个转弯的小路线；待 BACKTRACK enabled 后启动。确认剩余按轨迹长度、地图亮/暗部分随返回变化，返程 Ride 仍累计。
5. 暂停 Ride：指导隐藏且不自动恢复；Resume 等新 fix。停下时检验绝对方位说明、移动时仅用可信 course 的相对箭头。
6. 故意偏离至少约 30–50m（以实际 accuracy 和安全通行为准），检查 OFF TRACK/RETURN TO TRAIL、不出现 REROUTING；接回时解除，手动浏览不被重复事件抢页。
7. 另一个小回路或重复经过起点附近：未到 snapshot 末段不能提前 START REACHED；沿完整回程进入起点后 Arrival，Ride 不结束。End Backtrack 后继续短行，再 End Ride，检查完整 outward + return 保存并可导出。
8. 制造 Pause/GPS gap：地图断开，进入 TRAIL GAP 指向下一真实 endpoint，不显示假连接或把 gap 计入距离。大 gap 自行判断通行条件。
9. 两向模式冲突：分别取消和确认；取消旧 guidance 继续，确认旧 guidance 结束、新模式启动，无第二 Ride。
10. Backtrack active 下圆屏断开/重连：iPhone snapshot/progress 保留，现有 Speed fallback/手动页可用；**圆屏 Backtrack 箭头/路线恢复不在此次能力内，不能作为通过项**。锁屏数分钟后检查 GPS/后台 recording 与恢复后的进度。

## Architecture Check

| 检查 | 结果 |
| --- | --- |
| 使用实际 Ride track | 是，唯一 route 输入 |
| 使用 planned route | 否 |
| 调用地图 provider 重规划 Backtrack | 否；MapKit 底图不是 route provider |
| 创建第二个 Ride | 否 |
| 创建第二个 CLLocationManager | 否 |
| 修改 NavCore / Navigation matching | 否 |
| 假 maneuver / road / ETA | 无 |
| Ride lifecycle 独立 | 是，End/Arrival Backtrack 不结束 Ride |
| manual page browsing | 是，Driver 原规则保留，新 urgent 事件才恢复 fallback |
| Ride filtering / movingTime / Store schema / GPX / Share | 均未修改 |
| design/、commit、push | 均未修改/执行 |

## Remaining

- 任意 prior point。
- History Backtrack。
- Active Ride / Backtrack crash recovery。
- GNSS hardware support。

Round Display 的当前 Not wired 边界及必要后续 contract 已在独立章节明确，不以 future-ready 代码提前实现以上事项。

## Git Status

完整实际 `git status --untracked-files=normal`：

```text
On branch main
Your branch is up to date with 'origin/main'.

Changes not staged for commit:
  (use "git add <file>..." to update what will be committed)
  (use "git restore <file>..." to discard changes in working directory)
	modified:   platforms/ios/App/AppModel.swift
	modified:   platforms/ios/App/ContentView.swift
	modified:   platforms/ios/App/PresentationCoordinator.swift
	modified:   platforms/ios/App/PresentationDriver.swift

Untracked files:
  (use "git add <file>..." to include in what will be committed)
	design/
	docs/Waymate_Stage_7_Backtrack_Audit.md
	docs/Waymate_Stage_7_Backtrack_Report.md
	docs/ui/stage7-backtrack/
	platforms/ios/App/BacktrackSession.swift
	platforms/ios/App/BacktrackView.swift
	platforms/ios/AppTests/BacktrackReadoutTests.swift
	platforms/ios/AppTests/BacktrackTests.swift
	platforms/ios/AppTests/BacktrackWiringTests.swift
	platforms/ios/UITests/BacktrackUITests.swift

no changes added to commit (use "git add" and/or "git commit -a")
```

进入本轮前只有未跟踪 design/；该目录未作修改。全部改动留在工作区，未 stage、commit 或 push。
