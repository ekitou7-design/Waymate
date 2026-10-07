# Waymate Stage 4 — PresentationCoordinator Production Wiring

日期：2026-10-07。基线：`984a45f`。范围：现有圆屏页面的生产选择与同步；未 commit / push。

## Current Page Ownership

修改前的生产链是 `SharedNavigationRuntime → NavCore snapshot.display_page → ESP32BLECentral → BLE NavigationSnapshot → PhoneNavBridge → NavPresenter → shared/nav_ui`。Stage 2 Coordinator 只提供旁路判断，没有实际页面消费者。

ESP32 swipe 调用 `PhoneNavBridge::page_changed`，先更新本地 snapshot 并渲染，再发送现有 `DeviceCommand.PageSelected`。有导航 runtime 时，AppModel 将手动页写回 runtime 的 NavCore，后续快照保存该页；没有 runtime 时返回 invalidState，手机没有接受该页的同步路径。iPhone 快照与 ESP32 本地 swipe 都能改变显示页；正在传输的旧快照仍可能短暂覆盖即时本地页，随后手机接受的选择会同步回来。

reconnect 原本只恢复运输缓存中的最新 snapshot、geometry、Media state 和 map；没有按当前 Home 重新判断。NavCore reset/cancel 保留其 display_page；新 runtime 的默认页是 Navigation。没有生产 automatic temporary page 机制，也没有 previousPage 恢复机制。Media state 更新只刷新内容；Media 控制原本没有自动切页。

`nav_ui::show_page` 接收自动状态时不触发 page-change 回调；只有手动 gesture 路径触发该回调。因此现有 PageSelected 已能标识手动来源。横向 swipe 浏览 Navigation / Speed / Compass / Music，Music 受现有 Media capability 限制。tap 为内容交互/音乐控制；物理 PWR 按钮用于开关机，未发现 Home shortcut，本轮不新增。

## Production Wiring

```text
NavCore snapshot → NavigationComponentState ┐
AppModel-owned RideSession.isActive        ├→ PresentationDriver
已接受的 iPhone/ESP32 Media control event   ┘      ↓
                                        PresentationCoordinator.evaluate
                                                ↓
                                  有意义的 presentation event 去重
                                                ↓
                              RoundDisplayPage / AppModel display adapter
                                                ↓
                     ESP32BLECentral NavigationSnapshot.display_page
                                                ↓
                           PhoneNavBridge → NavPresenter → nav_ui
```

Driver 保存最新的只读 Coordinator Input，以便 expiry 使用当前导航/Ride 投影；AppModel 在每个相关生命周期操作及导航 snapshot 上刷新它。Driver 不启动、结束、暂停或恢复任何组件。所有生产回调在 MainActor 执行。

Driver 输出只由首次初始化、primary component 变化、Coordinator 返回的新 temporary eventIdentity、进入新的 offRoute/rerouting reason 或显式 resync 触发。普通距离、速度、位置、maneuver 数值刷新不再次选择页面。页面仍作为现有 snapshot 字段随必要的导航数据刷新传输；没有新增独立 page packet，也没有重复自动选择调用。AppModel 在一次 snapshot 触发选择后不再重复发送同一份 snapshot。

## Mapping

| Primary component | BLE v1 page | 显示语义 |
|---|---|---|
| idle | Navigation，raw 0 | 无导航时使用既有 Ready/lifecycle renderer |
| ride | Speed，raw 1 | 当前 Ride Home |
| navigation | Navigation，raw 0 | 现有导航与 Arrived |
| media | Music，raw 3 | 现有音乐页面 |

Compass 为已有手动浏览页，raw 2。映射集中在 `RoundDisplayPage`，没有新增协议页。Ready 保留既有连接成功短暂状态与连接降级表现。

本轮只接页面选择。Ride-only 的 Speed 内容仍消费已有 NavigationSnapshot 数据；未新增 Ride 指标 BLE 传输，未把 Ride tracking 数据伪装为 NavCore fix。没有可用导航 fix 时仍显示既有 unavailable 表达。

## Manual Browsing

ESP32 本地 swipe 后，通过既有 PageSelected 同步给 Driver；手机接受手动页时无需导航 runtime。Driver 保存 synchronized selectedPage，后续普通快照按这个值编码，Compass/Music 可以持续浏览。

Driver 的最小来源记录为 manualSelection 与当前自动窗口是否已被手动浏览撤销。手动选择撤销该窗口并取消 expiry task，保留已见 eventIdentity；它不是新的优先级系统。后续真正的 Home primary 变化、Coordinator urgent reason 进入事件或 reconnect 可重新选择。用户在持续 off-route 状态下再次 swipe，后续相同状态的 Tick 不重复抢回；off-route → rerouting 是新的可抢页事件。

Home 概念由 Coordinator 当前事实决定：有效 Navigation → Navigation；否则 active/paused Ride → Speed；否则 Idle → Ready。不存在物理 Home shortcut，未在本轮增加。

## Temporary Media

只有现有 AppleMusicRemoteController 接受的用户控制命令创建 interaction identity；拒绝、unsupported、自动 playback/progress 更新不创建事件。iPhone 与 ESP32 控制共用 AppModel.performMediaCommand；BLE 重复 commandID 已在运输层去重，只有首次接受会创建 UUID identity，reconnect 不重播命令。

自动 Media 沿用 Coordinator 的 5 秒 monotonic window。同一 eventIdentity 不重新延长、不重新选择；新 identity 可开启新窗口。一个可取消的 Task 使用 ContinuousClock deadline 安排 expiry，Coordinator 本身仍纯逻辑；没有 Timer/轮询状态机。到期重新 evaluate 最新投影，不返回 previousPage。暂停/恢复或新组件事实在 expiry 前发生，也会参与到期判断。

用户主动 swipe 到 Music 属于手动浏览，可持续停留；在该页操作控制也不建立会将其驱逐的自动窗口。自动 Music 展示期间再次手动浏览任何页，会撤销当前自动窗口。手动 Compass 上新的控制事件可以开启新的自动 Media window。

iPhone 既有主动 Media sheet 没有改动。Task 在 App 被挂起时可能延后执行；恢复执行、下一次事实刷新或 BLE resync 会依据 monotonic 当前时间判断，不能保证挂起期间严格第 5 秒切页。需真机验证锁屏/BLE/background 时序。

## Navigation Priority

完全沿用 Coordinator：已接受的有效导航且有 usable、非 stale fix，非 Arrived 状态下，rerouting / offRoute 优先于 Media。没有新增 maneuver 距离/速度/路线 urgency 算法。reason 从普通状态进入 offRoute/rerouting 时能从手动 Compass 抢回 Navigation；相同 reason 的连续快照不能重复抢页。

普通有效 Navigation 是 Home；Media 可以覆盖它。urgent 打断后，如果 urgent 解除且原 window 仍有效，Coordinator 可再次返回 Media，但不会续期。Arrived 仍属于 Navigation Home，直到 NavCore route/phase 清除；Arrival reason 变化本身不强制结束手动浏览，不结束 Ride。

End Navigation 且 Ride 仍 active/paused → Speed；End Ride 且 Navigation 有效 → Navigation 决策继续，已有手动浏览也保留。Paused Ride 不自动 Resume。

## Reconnect

最终 Device Ready 到达后，在 protocolReady 发送门打开前调用 Driver.resynchronize，按当前事实/当前时间更新运输基线。随后沿用 Stage 0 的 geometry + snapshot、Media state、map 恢复；不重复先发送一次页面再发送一次相同基线。

| 当前事实 | 恢复页 |
|---|---|
| 有效 Navigation | Navigation，并沿用 geometry/token/generation 恢复 |
| active/paused Ride，无 Navigation | Speed，不自动 Resume |
| Idle | Navigation 页的 Ready |
| 未过期的自动 Media window，且无 urgent Navigation | Music，保留原 deadline |
| Media 已过期，或已被手动浏览撤销 | 当前 Navigation / Ride / Idle Home |
| urgent Navigation | Navigation |

reconnect 会恢复 Home/有效自动 presentation，而不是恢复连接前的手动 Compass/Music。未改变 Stage 0 session gate、watchdog、重试、geometry batching、map ACK 和命令去重。实际掉电重连尚未执行。

## Source of Truth

| 项目 | 权威与缓存边界 |
|---|---|
| Navigation | iPhone C++ NavCore；NavigationComponentState 为只读投影 |
| Ride | AppModel-owned RideSession；Driver Input 的 isActive 只是事实快照，没有第二个 Ride 生命周期 flag |
| Media playback | 现有 AppleMusicRemoteController / PhoneMediaState |
| Media interaction | 接受用户控制后产生的 identity + startedAt；Driver 保存去重与 window 生命周期 |
| Presentation policy | 唯一 PresentationCoordinator；没有更改优先级规则 |
| 手机同步选择页 | PresentationDriver.selectedPage；包含已接受的 ESP32 手动选择 |
| BLE page / latest/pending snapshot | BLENavigationStateCache 为运输缓存，不拥有业务页策略；协议编码使用同步选择页 |
| ESP32 显示页 | PhoneNavBridge snapshot / nav_ui 为物理渲染状态与即时本地交互；PageSelected 回传后由手机快照同步 |

NavCore 原有 display_page 字段与 bridge API 未改，仍供原有跨平台能力使用；iOS 生产输出已由 Driver selection 覆盖该字段。删除 SharedNavigationRuntime 的 page selection 方法，避免把 NavCore 页值继续作为手机 presentation owner。Coordinator 没有 currentPage，AppModel 没有另建 currentPage。

## Changes

| 文件 | 修改 |
|---|---|
| platforms/ios/App/PresentationDriver.swift | 新增现有页映射、事件交付、来源记录与一次 expiry task |
| platforms/ios/App/AppModel.swift | 接入事实与 Media control；恢复回调与 display adapter；初始化 Idle 基线 |
| platforms/ios/App/Adapters/BLE/ESP32BLECentral.swift | page 运输缓存与编码；在 final Ready 前更新恢复基线 |
| platforms/ios/App/Adapters/Navigation/SharedNavigationRuntime.swift | 删除不再使用的 page selection 方法 |
| platforms/ios/App/PresentationCoordinator.swift | 仅更新生产消费者说明注释，policy 零改动 |
| platforms/ios/AppTests/PresentationProductionWiringTests.swift | 新增 20 项接线/生命周期/编码/expiry 测试 |
| docs/Waymate_Stage_4_Presentation_Report.md | 本报告 |

## Tests

| 检查 | 最终结果 |
|---|---|
| PresentationCoordinatorTests | 14/14 |
| PresentationProductionWiringTests | 20/20 |
| RideProductionWiringTests | 11/11 |
| RideSessionTests | 13/13 |
| RideTrackingTests | 23/23 |
| NavigationComponentStateTests + NavigationReadoutTests | 16/16 |
| 全部 iOS AppTests / WaymateUnitTests | 146/146，0 failures |
| Swift package tests | 19/19，0 failures |
| XcodeGen | 成功 |
| unsigned iPhoneOS build | BUILD SUCCEEDED |
| git diff --check | 通过 |
| native/C++、ESP-IDF build | 未运行：ESP32/shared/C++ 没有实际改动 |

23 项用户场景覆盖：Idle/start-stop Ride、Ride ordinary update、start/end Navigation、Nav ordinary snapshots、manual Compass、offRoute/rerouting、End Ride with Nav、Media expiry 的三个 Home、新旧 identity、manual Music、Media urgency interruption、Navigation/Ride/expired Media resync、paused Ride、Arrived、BLE unavailable。Driver 以注入时间测试，另有真实生产 Task 的已过期 deadline 测试，验证无 Nav Tick 也 reevaluate，以及手动选择取消 task。BLE 编码测试验证四个正式页与导航事实独立。

没有删除旧测试。Swift 初次沙箱测试因 Clang module cache 权限失败；提升执行权限后 package 全部通过。初次沙箱 CoreSimulator 探测不可访问，提升权限后 Simulator tests 全部通过。既有 Ride route-failure 测试会产生故意无效网关的 TLS/network 错误日志，测试结果通过；这不证明真实 route provider 可用。构建有既有 AppIntents metadata extraction skipped 警告，无构建失败。

验证命令：

```sh
swift test --package-path platforms/ios --scratch-path /private/tmp/waymate-stage4-swift
# 在 platforms/ios 内执行
xcodegen generate
# 在仓库根执行
xcodebuild -project platforms/ios/Waymate.xcodeproj -scheme Waymate \
  -destination 'platform=iOS Simulator,id=27A3C4CE-42DD-4981-B7F7-E816B39BACB4' \
  -derivedDataPath /private/tmp/waymate-stage4-tests \
  -resultBundlePath /private/tmp/waymate-stage4-verified-app-tests.xcresult \
  -only-testing:WaymateUnitTests CODE_SIGNING_ALLOWED=NO test
xcodebuild -project platforms/ios/Waymate.xcodeproj -scheme Waymate \
  -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/waymate-stage4-ios \
  CODE_SIGNING_ALLOWED=NO build
git diff --check
```

完整日志与结果：`/private/tmp/waymate-stage4-verified-app-tests.log`、`/private/tmp/waymate-stage4-verified-app-tests.xcresult`、`/private/tmp/waymate-stage4-verified-ios-build.log`、`/private/tmp/waymate-stage4-swift.log`。没有运行 UI automation 或实际 BLE/Apple Music 权限控制链。

## Behavior Changes

开始 Ride 会自动进入 Speed，接受 Navigation 路线后进入 Navigation；结束 Navigation 会回仍在进行的 Ride。真实 urgent reason 能打断手动浏览。已接受的 Media 控制可以触发自动 Music 窗口，到期按当前事实回 Home。主动 Music 浏览保持停留。无导航 runtime 时也接受并同步 swipe。启动与重连有明确的 Idle/Ride/Navigation 基线，已过期 Media 不复活。页面内容、排版和功能界面保持本轮前的实现。

## Architecture Check

| 问题 | 答案 |
|---|---|
| 第二个 PresentationCoordinator / priority policy？ | 否；Driver 只消费既有 decision 与 reason |
| BLE v1 schema / UUID / packet layout 修改？ | 否 |
| NavCore 修改？ | 否 |
| RideSession / tracking / GPS filtering 修改？ | 否 |
| iPhone / Round Display UI、字体、地图 visual 修改？ | 否 |
| page command spam？ | 100 次普通 refresh 仅初始化/真正事件选择；必要 snapshot 仍携带当前页 |
| manual page browsing 保留？ | 是；手动页持续到下一次真正 presentation event / resync |
| ESP32 业务策略新增？ | 否，ESP32 零修改 |
| PRD / design / commit / push？ | 均未修改或执行；原有未跟踪 design/ 保留 |

## Real-device Test Plan

本轮未执行。最短流程：

1. 手机运行最终构建，圆屏连接：Idle 显示既有 CONNECTED → READY。
2. Start Ride：进入 Speed；等待若干真实 location update，无重复抢页。Pause 后重连仍是 Ride Home，不 Resume。
3. 在 Ride 中开始真实 Navigation：接受路线后进入 Navigation，确认路线 geometry。
4. swipe 到 Compass，保持多个 location/navigation Tick：仍停留 Compass。
5. 安全条件下验证真实 NavCore off-route/rerouting：回 Navigation；相同 urgent 状态再次 swipe 后不应每 Tick 强抢。不能制造危险驾驶场景。
6. 在非 urgent Navigation / Ride 下，从 iPhone Media sheet 控制已获授权 Apple Music：圆屏暂时进入 Music，约 5 秒后按当前事实回 Home。再次 swipe 主动进入 Music 并控制，等待超过 5 秒仍停留；重发同一 BLE commandID 不续期、不重复播放控制。
7. End Navigation：Ride 继续且页面回 Speed。End Ride：回 Ready。Arrived 时 Ride 继续。
8. Navigation 中 ESP32 power off → on：恢复 Navigation + geometry；Ride-only 重复：Speed；Idle 重复：Ready；Media 自动窗口过期后重连：当前 Home，不能复活 Music 或重播命令。

同时观察稀疏 `[Presentation]` 日志，普通 Tick 无该类 transition log；记录从本地 swipe 到手机同步的时延与是否出现旧队列短暂闪回。锁屏、background 与真实 Media authorization 需单独记录。

## Git Status

```text
On branch main
Your branch is up to date with 'origin/main'.

Changes not staged for commit:
  (use "git add <file>..." to update what will be committed)
  (use "git restore <file>..." to discard changes in working directory)
	modified:   platforms/ios/App/Adapters/BLE/ESP32BLECentral.swift
	modified:   platforms/ios/App/Adapters/Navigation/SharedNavigationRuntime.swift
	modified:   platforms/ios/App/AppModel.swift
	modified:   platforms/ios/App/PresentationCoordinator.swift

Untracked files:
  (use "git add <file>..." to include in what will be committed)
	design/
	docs/Waymate_Stage_4_Presentation_Report.md
	platforms/ios/App/PresentationDriver.swift
	platforms/ios/AppTests/PresentationProductionWiringTests.swift

no changes added to commit (use "git add" and/or "git commit -a")
```
