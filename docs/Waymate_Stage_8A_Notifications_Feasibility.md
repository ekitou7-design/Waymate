# Waymate Stage 8A: iPhone Notifications → Round Display Feasibility & Architecture Audit

审计日期：2026-10-08（Asia/Shanghai）。仓库基线：`d46fe0d2a508e7ce4cce5ba64b6687d7448cc69f`，`main`，最近提交 `feat: add round display backtrack`。

范围：技术可行性、平台约束和最小 proposed architecture。未开始 Stage 8B；未修改生产代码、协议、固件、字体或 `design/`；未 commit / push。本文的容量与消息设计均为提案，不代表已实现。

## Executive Conclusion

**Waymate 开源 V1 有正式可用的通知获取路线：ESP32 直接作为 ANCS client；建议进入有门槛的 Stage 8B 验证，当前不能宣布中文 Notification Center 已具备交付条件。**

推荐 Option B：iPhone 系统 ANCS → ESP32；Waymate App 继续提供 Navigation / Ride / Backtrack / Media、ANCS 授权引导、显示筛选设置和真实 Ride 上下文。原则上沿用一条 BLE 物理连接，在两端各增加相反方向的 GATT 服务访问，不另建第二条“通知连接”。Apple 2026-09-21 的附件指南仍列出 ANCS，当前本机 SDK 也具有 ANCS 授权 API。[Apple 当前附件指南 §58.12.4，p.355](https://developer.apple.com/accessories/Accessory-Design-Guidelines.pdf)、[Core Bluetooth ANCS 连接选项](https://developer.apple.com/documentation/corebluetooth/cbconnectperipheraloptionrequiresancs)。

| 分级 | 本次判断 | 产品含义 |
| --- | --- | --- |
| Green | ANCS 是公开的 BLE 附件路线；可获得通知事件、app identifier、可选文本、类别及有限动作 | 可由 DIY 固件实现；不需要让普通 iOS App 读取其他 App 通知，也不需要专用通知 forwarding entitlement |
| Green | 普通 CoreBluetooth App 能协助请求/观察 ANCS 授权；ESP32 可本地计算 unread badge、维护当前 Ride 的内存列表 | 这些能力可进入 V1 实现范围，但本轮只是审计 |
| Yellow | 当前 NimBLE 配置缺少 GATT client；同一连接的双向 GATT、系统持续连接、授权撤销、重连均未在 Waymate 实机验证 | 8B.1 必须通过后才能继续；不能用 SDK 编译结果替代硬件结果 |
| Yellow | 中文需要新增大范围本地字体；当前配对没有 MITM 认证、没有明确唯一 owner 准入 | 正式显示私人正文前，字体和身份保护必须过关 |
| Yellow | 新 AccessoryNotifications + 三种 extension 可支持丰富通知和 text-input reply | 当前官方最低 iOS 26.5；用户安装限欧盟，签名资格未实测；适合作为未来欧盟分支研究 |
| Red | 普通 App 用 UserNotifications 读取微信/短信等其他 App 的通知 | 公开 API 不提供这条通道 |
| Red | ANCS 自定义五条文本 quick replies、完整任意 Unicode/emoji、可靠系统 unread/read 同步、保证每一种 VoIP 电话可控 | 不应作为 V1 承诺 |
| Red（针对全球 V1） | 用新 forwarding 框架作为所有 GitHub 用户的统一通知方案 | 地区条件已足以排除；不能以“开发可在任何地区测试”替代用户可用性 |

Green 表示存在适合当前开源产品的正式实现路径；不表示当前仓库已有功能或实机验收通过。

## Current Architecture

### 链路和 authority

```text
iPhone AppModel
  ├─ RideSession / SharedLocationSource：真实 Ride 生命周期与轨迹
  ├─ NavCore → NavigationComponentState
  ├─ BacktrackSession → BacktrackComponentState
  ├─ AppleMusicRemoteController → PhoneMediaState
  └─ PresentationCoordinator → PresentationDriver → 当前圆屏 page
       ↓
ESP32BLECentral / MotoBLEProtocolBridge
       ↓ 自定义 BLE v1 / 加密 GATT
BleNavTransport → PhoneNavBridge retained state
       ↓ 唯一 render task
NavPresenter / shared nav_ui → LVGL 466 × 466 圆屏
```

`AppModel` 拥有真实 `RideSession`，`rideActive` 是只读投影。`PresentationCoordinator.evaluate` 为纯 Primary Page 策略，枚举为 Idle / Ride / Navigation / Backtrack / Media；没有通知输入。`PresentationDriver` 处理手动浏览、临时 Media、紧急返回、重连重新选择。现有 `.idle` 与 `.navigation` 映射圆屏 page 0，Ride 对应 speed，此外有 compass、music、backtrack；“Primary Component”与“圆屏工具页”不是一一对应。

`PhoneNavBridge` 将 BLE callbacks 的数据留存并交给唯一 render task；`NavPresenter` 映射 Navigation / Backtrack 到 UI。通知将来也应由该渲染线程提交，不能在 NimBLE callbacks 里操作 LVGL。

Media 实际路径为 Apple Music 系统播放器 → `PhoneMediaState` → `sendMediaState` → v1 `MediaState`（0x13）→ `consume_media` → music UI。圆屏控制通过 `DeviceCommand` 16…19 返回 AppModel，未支持的 Like 保持 unsupported。MediaPlayer 的本地 `NotificationCenter` observers 是播放器状态事件，**不是 iOS 系统通知读取能力**。

### 要求中的七项确认

| 检查项 | 当前结果与证据 |
| --- | --- |
| notification 实现 | 在 `platforms/ios/App`、`project.yml`、`platforms/esp32/main`、共享协议/UI 范围未发现 ANCS、AccessoryNotifications、UNUserNotificationCenter 集成或 Notification Center 模型。BLE `didUpdateNotificationStateFor` 等是 GATT notify，不是用户通知；Media 使用进程内 NotificationCenter |
| App Extension targets | `project.yml` 与生成的 `Waymate.xcodeproj/project.pbxproj` 只有 Waymate application、unit tests、UI tests；无 `.appex` target |
| entitlements | `App/Waymate.entitlements` 为 `<dict/>`；没有 accessory forwarding、APS 或 notification entitlement |
| BLE | 只有 CoreBluetooth `CBCentralManager`；当前 `central.connect(peripheral)` 没有 `RequiresANCS` option，没有授权 callback / ancsAuthorized 投影；未用 AccessorySetupKit / ExternalAccessory |
| 协议可扩展性 | v1 有 message type、payload revision、capability bits、fragmentation、CRC、ACK 和 command IDs；适合 capability-gated additive 扩展，但旧 codec 的 type / enum validation 会拒绝未知值，不能只新增 enum 就向旧设备发送 |
| overlay / badge primitive | `make_layer`、labels、page dots、连接状态呈现和 gesture callbacks 可复用；没有语义上的 Notification Layer、unread badge 或通知列表。普通 LVGL layer 是构建材料，不等于已有通知组件 |
| Coordinator 边界 | 仅决定 Primary Component / reason / temporary expiry / urgent identity。通知不应进入 `primaryComponent`，本次不改 policy |

主要代码位置（路径相对仓库）：

- `platforms/ios/App/AppModel.swift`：6（所有权），98（Ride 投影），127（start/pause/resume/stop），359（DeviceCommand / Media / Presentation wiring），811（圆屏发布）。
- `platforms/ios/App/PresentationCoordinator.swift`：1；`PresentationDriver.swift`：1。
- `platforms/ios/App/Adapters/BLE/ESP32BLECentral.swift`：435（connect），558（实际 write 上限），646（resync），953（Media 缓存重发）。
- `platforms/ios/App/Adapters/BLE/MotoBLEProtocolBridge.h/.mm`；`shared/ble_protocol/include/moto/ble_protocol/ble_protocol.hpp`：33、112、270、579。
- `platforms/esp32/main/ble_nav_transport_nimble.cpp`：97（security），137（GATT permissions），208（GAP events），361（worker / epoch），687（发送门控）；对应 `.h`：49（frame / queue bounds）。
- `platforms/esp32/main/phone_nav_bridge.h`：19（renderer ownership）；`.cpp`：323（link reset），514（消息路由），862（Media），1010（render），1118（commands）。
- `shared/nav_presenter/include/moto_nav_presenter.hpp`；`shared/nav_ui/include/moto_nav_ui.h`；`shared/nav_ui/src/moto_nav_ui.cpp`：246（layer）、514（swipe）、2174（screen/pages）。

### reconnect / resync

现有 iOS 使用 CoreBluetooth restoration、自定义 Starting / Ready 握手、session validation，以及 Navigation / Backtrack / MapScene / Media 最新状态重发。ESP32 `ConnectionEpochGate` 在物理断连时重置 reassembler / watchdog / ACK，避免旧队列消息跨 connection epoch 被采用。`PhoneNavBridge` 还有自定义 phone session 与 watchdog 所产生的 link 状态。

**后续要区分三种结束条件：BLE 物理连接结束、ANCS subscription session 结束、自定义 Waymate App session 结束。** App 重启可以发生在系统维持同一 BLE 连接时；自定义 heartbeat 超时也不等于 ANCS 已断开。不能把这些身份合并。

### iOS 构建与签名

`project.yml` 是配置来源：deployment target iOS **17.0**，声明 Xcode **16.0**，Swift 5.0，iPhone only，Automatic signing，team `R42CXWKWNJ`，bundle `com.zhengxiaohua.waymate.test2026`。生成项目的 application settings 与其一致。Info.plist 的 background modes 为 `location`、`bluetooth-central`；有 Bluetooth / location / Apple Music usage descriptions，没有 ASK 配置或通知 extension 配置。

team ID 本身不能证明是 Personal Team 或付费会员。本次没有读取 Developer Portal、私人账户或 provisioning profile；也没有新 entitlement 的签名/安装结果。

## iOS Platform Findings

### A. 普通 iOS App

`UNUserNotificationCenter` 只管理调用 App / extension 自己的通知、类别与响应。`getDeliveredNotifications` 不提供其他 App 的 title、body、source app、actions 或 unread/read 状态。Notification Service / Content Extension 也不是全局通知监听器；`aps-environment`、critical alerts 等不能赋予跨 App 通知读取能力。[UNUserNotificationCenter](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter)。

`CBPeripheral.ancsAuthorized` 是“附件是否获准使用 ANCS”的状态，不能把 ANCS 数据交给普通 App。Apple 当前附件指南 §58.14（p.355–356）说明 ANCS 是系统内置服务，不允许第三方 App 发布，且从 App 的 accessory discovery 结果中过滤。[当前附件指南](https://developer.apple.com/accessories/Accessory-Design-Guidelines.pdf)。

因此 Option A 对第三方通知不可用；Waymate 自己生成的提示可沿普通 BLE 发送，但不是系统通知转发。

### B. 新 accessory notification forwarding

正式 framework 为 **AccessoryNotifications**，与 **AccessoryTransportExtension**、**AccessorySetupKit** 协作，不是 ExternalAccessory 的 MFi 串口。当前官方 DocC metadata（实时读取）如下：

| Framework / symbol | 官方 `introducedAt` / 条件 |
| --- | --- |
| AccessoryNotifications、AccessoryNotification、NotificationResponse | iOS **26.5**，`beta: false` |
| AccessoryTransportExtension 基础 framework | iOS **26.2**；不能据此声称 notification forwarding 也只需 26.2 |
| accessory-data-provider / accessory-transport-security entitlements | iOS 26.5（entitlement 文档也标 iPadOS；通知 framework 本身明确 iPhone only） |
| accessory-transport-extension entitlement | iOS 26.2 |
| 客户安装地区 | **设备位于欧盟，并登录欧盟国家/地区 Apple Account** |
| 开发测试 | 官方允许在任何地区开发和测试；不取消客户安装条件 |

来源：[AccessoryNotifications](https://developer.apple.com/documentation/accessorynotifications)、[AccessoryTransportExtension](https://developer.apple.com/documentation/accessorytransportextension)、[官方 extension 接收流程](https://developer.apple.com/documentation/accessorytransportextension/receiving-ios-notifications-on-an-accessory)。早期 26.3 beta / DMA 公告不能代替当前 symbol availability；本报告按当前公开 API 的 26.5 判断。

最低工具链应提供 iOS 26.5 SDK；Apple 当前 Xcode 对照表中 Xcode **26.5** 带 iOS 26.5 SDK（26.3 带 26.2、26.4.1 带 26.4）。本机只有 Xcode **16.4 / 16F6** 与 iPhoneOS **18.5** SDK，没有两个新 framework，当前工程不能编译该路线。[Xcode SDK 对照表](https://developer.apple.com/xcode/system-requirements)。

官方工作流：ASK 返回 `ASAccessory` → companion app `requestForwarding(for:)` → 系统让用户选择全部/部分/不允许 → `AccessoryDataProvider` 收取/整理内容 → `AccessoryTransportSecurity` 提供 key exchange → 系统加密 → `AccessoryTransportAppExtension` 只转运密文 → 附件 HPKE 解密并显示。支持 Bluetooth transport，也存在 localNetwork / internet transport；不是要求一条 MFi 专有硬件链。[接收流程](https://developer.apple.com/documentation/accessorytransportextension/receiving-ios-notifications-on-an-accessory)。

**对 Waymate 的具体判断：** BLE ESP32 在传输类型上没有被排除；但现有 AppModel 和 BLE adapter 不能直接充当上述三种 extensions。需新 targets、ASK onboarding、官方安全封装和附件 HPKE；不能把新 API content 直接塞进现有明文 payload 而省略官方端到端保护。正式用户地区条件与 Waymate 全球 DIY 目标冲突，因此不推荐 V1。

该公开工作流未列 MFi certification 或专有 accessory transport 为前提；不能据此额外声称必须商业 accessory program。另一方面，文档声明 entitlement 存在，**没有证明 Personal Team 能签出它们**，也没有明确说明三项都需要 Apple 人工批准。资格未知应保留未知，详见 Entitlements，不能把“需要 entitlement”写成“已确认需要单独审批”。

### C. ANCS

ANCS 是 iPhone 系统公布的 BLE GATT service。iPhone 是 Notification Provider / GATT server，ESP32 是 Notification Consumer / GATT client。**GAP central/peripheral 与 GATT client/server 是两组角色。** 推荐连接上 iPhone 仍为 GAP central，ESP32 仍为 GAP peripheral；现有自定义服务方向则是 iPhone GATT client → ESP32 GATT server。

当前 R31 附件指南（2026-09-21）§58.1 推荐 accessory peripheral，§58.10 描述 iPhone 同时作为 central 与 GATT server，§58.12.4 明确从 iOS 7 提供 ANCS；§58.14 描述动态数据库和服务过滤。当前 Apple Bluetooth 页面仍链接 ANCS；本机 iOS18.5 SDK 保留 iOS13 起的授权 API。**这是当前官方支持证据，不是本轮已验证某台 iOS26/27 手机的实机行为。** [附件指南 p.350、353–356](https://developer.apple.com/accessories/Accessory-Design-Guidelines.pdf)、[Apple Bluetooth](https://developer.apple.com/bluetooth/)。

ANCS 不需要 Waymate App 作为内容中转；App 可帮助建立已有连接并改善权限时机。基本协议使用 Notification Source、可选 Control Point / Data Source；需授权访问、订阅 Service Changed，处理 ANCS 暂时不出现或被撤下。[ANCS specification](https://developer.apple.com/library/archive/documentation/CoreBluetooth/Reference/AppleNotificationCenterServiceSpecification/Specification/Specification.html)。

ANCS 是普通 BLE 路线，不要求为 ESP32 申请 forwarding entitlement。Apple MFi FAQ 将仅用 BLE / CoreBluetooth 的附件排除在 MFi 之外；无需把公开 ANCS 与需要 MFi 的 ExternalAccessory / iAP 混淆。[MFi FAQ](https://mfi.apple.com/en/faqs)。

## Comparison

| 方案 | 内容获取者 / 数据路径 | 授权和筛选 | Quick reply | 开源/当前工程判断 |
| --- | --- | --- | --- | --- |
| A App → Waymate BLE → ESP32 | 普通 App 先读其他 App 通知 | UserNotifications 仅自己 App | 他 App 不可用 | **Red**；只能发 Waymate 自有消息 |
| B ESP32 → iPhone ANCS | 系统直接交给附件，App 不读正文 | bonding + ANCS consent；附件按 app identifier 自行显示筛选 | 没有自定义文本命令；仅两类预定义 action | **推荐**；平台 Green，Waymate 集成/security/font Yellow |
| C 新 framework / extensions → accessory transport | DataProvider 整理，系统加密，transport 转密文，ESP32 解密 | ASK + 系统按 App 选择 | textInput action 存在时可发配置文本 | **Yellow（欧盟条件）/ Red（全球统一 V1）**；本机 SDK 不具备 |
| C 的官方 internet 变体 | 同一新 framework，经服务器/网络送附件；响应可经 APNs | 同一授权/资格/地区体系，不绕过限制 | 同 C | 不推荐；新增服务器、网络依赖和密钥协议，圆屏骑行链无此需求 |

internet 变体是真实官方方案，但不是“服务器能直接读取 iPhone 通知”。[官方 internet transport 流程](https://developer.apple.com/documentation/accessorytransportextension/forwarding-notifications-to-your-accessory-using-the-internet-transport-type)。

## Entitlements

| 路线/target | 所需项 | 结论 |
| --- | --- | --- |
| B 普通 iOS companion app | `NSBluetoothAlwaysUsageDescription`；已有 `bluetooth-central` background mode；可用 CoreBluetooth ANCS consent APIs | 无 ANCS 专用 App entitlement，无 Notification Extension 必要性；Personal Team 在 ANCS API 层没有额外 forwarding 资格门槛。App 安装仍遵循个人签名限制，本次未签名安装验证 |
| B ESP32 | 配对/bond keys、encrypted link、iOS 用户授权 | 不是 Apple App code-sign entitlement，也不是 MFi 申请 |
| C DataProvider extension | `com.apple.developer.accessory-data-provider = true` | 官方明确要求，availability 26.5 |
| C Security extension | `com.apple.developer.accessory-transport-security = true` | 官方明确要求，availability 26.5 |
| C Transport extension | `com.apple.developer.accessory-transport-extension = true` | 官方明确要求，availability 26.2 |
| C 扩展声明 | 官方示例明确给出 `com.apple.accessory-data-provider`、`com.apple.accessory-transport-security` extension points；DataProvider capability `AccessoryNotifications.NotificationsForwarding`；Transport target 按其 protocol / configuration 配置 | 是新 extension 生命周期，不能仅加一个 entitlement 到现有主 App |

三项 entitlement 官方页面：[Data provider](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.accessory-data-provider)、[Transport security](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.accessory-transport-security)、[Transport](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.accessory-transport-extension)。

**C 的 Personal Team 支持：未确认。C 是否需 Apple 单独批准：公开文档未明确，未确认。** 本次核对 entitlement 页面和 [supported capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-ios/)；后者没有给出这些新能力的明确 Personal Team 矩阵。未登录 Portal、未取得 profile、未绕过签名。未来若研究 C，必须在具备 iOS26.5 SDK 的隔离项目逐项检查 profile 包含三个 entitlements，并实测安装及 extension 启动；不能用 unsigned compile 当资格证明。即使签名通过，欧盟用户条件仍然存在。

C 的通知及 associated keys 不应被转给其他设备；Apple 协议还限制远端保存、profiling 等用途。若未来实施 C，应核对当时协议原文，特别是附件向 iPhone 回传 plaintext 内容的限制。[Apple Developer Program License Agreement，Accessory Notifications / Live Activities 条款](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/)。这不是对 ANCS 附加同名 entitlement 的理由。

## Open-source Viability

**B 可复现性最好。** 用户可自己编译附件 ANCS client，公开规格与普通 BLE 足够；不需要发行商代申请通知 entitlement，也不需要 MFi 加密芯片。Waymate App 可用已有普通 CoreBluetooth 链，开发者账号费用/个人签名过期问题属于既有 iOS DIY 安装限制，不是 ANCS 新增门槛。

“自己编译即可用”仍以匹配硬件、能完成配对/授权、固件具有 GATT client、字体资源安装正确为前提；当前仓库不具备 ANCS client，不能承诺 clone/build 现版本就有通知。实现时应保留 OFF / badge-only 能力和清晰兼容说明。

C 不能成为中国等非欧盟用户的 V1 默认路线；不能仅因公开文档就宣称所有免费账号可复现，也不能无证据宣称只供商业 MFi 厂商。

## Dual BLE / Connection Feasibility

### 推荐的一条连接

```text
                       同一 encrypted / bonded BLE link
iPhone GAP central  =================================  ESP32 GAP peripheral
Waymate GATT client  → 自定义 Waymate service          → ESP32 GATT server
iOS ANCS GATT server ← Notification Source/Data Source ← ESP32 GATT client
```

service UUID 和 characteristic handle 分属两端 GATT 数据库，不与现有 `7e57a000…` 自定义服务冲突；不在 ESP32 上伪造 ANCS server，也不在 iPhone App 中重新发布系统 ANCS。

### 与当前实现逐项对照

| 项 | 当前事实 | 未来最小要求 |
| --- | --- | --- |
| GAP / GATT | defaults: peripheral=y、central=n、observer=n、server=y、client=n；单一 `connection_handle_` | 保持运行时 peripheral 与单连接；增加 GATT client 编译能力 |
| IDF 特殊依赖 | 本机 IDF **v5.5.5** `components/bt/host/nimble/Kconfig.in:106` 的 GATT_CLIENT **depends on ROLE_CENTRAL** | 虽然运行时 ANCS 不需 central 去发起第二连接，构建上需同时启用 central 能力才能打开 client；不能只改 client=y |
| APIs / callbacks | 本机头文件有 `ble_gattc_disc_svc_by_uuid`、`ble_gattc_disc_all_chrs`、`ble_gattc_write_flat`；有 `BLE_GAP_EVENT_NOTIFY_RX`；当前 gap handler 未消费 incoming notify | 在现有 conn_handle 上发现 iPhone ANCS；dispatch incoming notify / Service Changed，与 ESP32 TX subscription events 分开 |
| bonding/encryption | LESC requested、bonding=1、MITM=0、NoInputNoOutput；RX WRITE_ENC、TX NOTIFY_INDICATE_ENC | 复用同一真实 bond，检查 encrypted+bonded peer、ANCS consent；不把设备“Ready”误作通知授权 |
| resources | MAX_CONNECTIONS=1，MAX_BONDS=3，GATT_MAX_PROCS=4，MAX_CCCDS=8；host stack 4096B，internal allocation | 同一连接无需增加 connection count。新增 discovery / writes 的过程和 mbuf 有预算；server CCCD 池与远端 client 订阅不可简单混算 |
| reconnect | 现有单连接 epoch、v1 session、watchdog、自定义状态 resync | ANCS 有独立 subscription epoch；重订阅/rediscover，不复用旧 UID 和 actions |
| pairing | 首次访问加密 custom attributes 可触发系统 pairing；repeat pairing 当前会删除 peer bond 后 retry | 应用已有 bond，处理忘记设备/拒绝/撤权；正式通知之前限制任意 repeat-pair 的自动接纳 |

本机构建目录 `project_description.json` 指向 `/Users/zhengxiaohua/esp/esp-idf-v5.5.5`。当前生成的 sdkconfig 也未启用 central；client=n 的配置来源为 defaults。API availability 加 Kconfig 分析表明可扩展，**不是当前固件支持 ANCS 的证明**。[ESP-IDF v5.5.5 NimBLE](https://docs.espressif.com/projects/esp-idf/en/v5.5.5/esp32s3/api-reference/bluetooth/nimble/index.html)。

8B.1 的硬门槛：现有 custom Ready / Navigation 更新同时运行时，在同一实际 conn_handle 上完成 ANCS discovery、Data Source 与 Notification Source CCCD 订阅、真实通知接收；覆盖锁屏、App suspended / terminated、断连、已 bonding 重连。若实测单连接不能兼容，停止并重新审计。**不直接把 MAX_CONNECTIONS 改成2**：当前单 handle、全局 encrypted/subscribed flags、单 reassembler/session/watchdog 并不是多连接设计，第二连接会需要另一个范围的改造。

## User Authorization & App Selection

| 路线 | 第一次的真实授权流程 | 按 App 控制的实际能力 |
| --- | --- | --- |
| A | Waymate 自己的通知 authorization prompt、Bluetooth permission | 只控制 Waymate 自己发出的通知，不能选择其他 App 作为输入 |
| B | Waymate Bluetooth 权限 → 连接 → 受保护 GATT 访问触发 pairing（若已有 bond 可省）→ iOS 附件通知分享同意 | ANCS 规格没有系统按 App allowlist 接口。可在 accessory 取得 app identifier 后实施 Waymate **显示筛选** |
| C | ASK accessory setup / authorization → companion `requestForwarding(for:)` → 系统选择全部、部分、拒绝 | 官方系统支持 subset of apps，`ForwardingDecision.limited`；可以用 `presentSettings` 再管理 |

ANCS 从 iOS13 起要求用户同意；使用 `CBConnectPeripheralOptionRequiresANCS` 可把系统通知分享提示放到连接/配对完成后、用户仍在 companion app 的时机；`didUpdateANCSAuthorizationFor` 和 `ancsAuthorized` 可观察结果。权限可在 Settings → Bluetooth → 对应附件设置调整。具体中英文弹窗标题、顺序和菜单文案随 OS 变化，本轮未截图验证，不把猜测的 “Allow Notifications?” 字样当固定 UX。[Apple WWDC19 privacy flow](https://developer.apple.com/videos/play/wwdc2019/901/)。

建议 B 产品流程：Notifications 默认 OFF，用户主动开启时先说明“iPhone 会向附件分享通知；Waymate 的筛选发生在附件，不是系统按 App 授权”。未知来源默认不展示；每条 Added 先只取 app identifier，匹配 allowlist 后才考虑 fetch title/body。拒绝或撤销不影响 Navigation / Ride。

App 无公开全局“已安装 App 列表”来填充任意通知 App picker。最小做法为用户主动配置来源，或在明确开启后的真实事件中学习 source identifier / display name（只同步来源元数据到设置界面）。未见过的 App 不能用假列表填充。ANCS 不提供 app icon；V1 通用信封图标/来源文字足够，不承诺自动取得微信官方图标。

来源筛选不能阻止 iOS 先发送 ANCS event / UID / category 给已获授权附件；只能减少后续正文获取和本地呈现。系统 notifications、Focus、preview 隐私设定、锁屏及 source App 差异会影响能拿到什么，任何拿不到的字段保持 unavailable；需要在8B实机矩阵核验。

## Notification Data

### 真实可获取字段

| 字段 | B：ANCS | C：新框架 | V1 proposed model |
| --- | --- | --- | --- |
| identity | 32-bit NotificationUID，仅当前 ANCS session 有效 | identifier 包含 notificationIdentifier / sourceIdentifier | B 使用 `(owner bond, ancsEpoch, UID)`，不得当永久 ID |
| source | AppIdentifier；Get App Attributes 可取 DisplayName | identifier.sourceIdentifier（bundle ID）、sourceName、sourceIcon | sourceIdentifier + optional displayName；图标用通用图形 |
| title / subtitle | 可请求，空/缺失合法 | optional title / subtitle | 原样来源字段，optional；不自动改名为 sender |
| message | 可限制字节请求的 UTF-8 Message，MessageSize | NSAttributedString body，可带 genmoji/附件 | 仅 bounded preview；不保存全文或附件 |
| time | Date string，没有时区 offset 字段；缺失可能 | deliveryDate / displayDate | optional sourceDateRaw + 本地接收的 monotonic time；不伪造精确 UTC |
| category | CategoryID，best effort；CategoryCount | AlertingContext.kind / attributes，语义不等于 ANCS category | raw ANCS category，保守呈现 |
| events | Added / Modified / Removed | add / update / remove / removeAll | 本地 upsert / remove；不把 Modified 算新 unread |
| actions | positive / negative presence flags、可选 labels | actions 数组及 action type | 只保留真实可执行 actions；默认 V1无系统动作按钮 |
| unread/read | **没有每条系统 read flag**；CategoryCount 不是 Waymate unread | 有 responses/actions，不等于全局可查询 unread flag | 仅 Waymate displayViewed；不声称系统已读 |
| sender / contact / avatar | 没有结构化独立 sender/contact 字段 | contextIcon 等并不保证通用联系人模型 | 不设计独立必填 sender；微信标题可能像姓名，仍标 title |

字段依据：[ANCS Appendix](https://developer.apple.com/library/archive/documentation/CoreBluetooth/Reference/AppleNotificationCenterServiceSpecification/Appendix/Appendix.html)、[ANCS Introduction（UTF-8）](https://developer.apple.com/library/archive/documentation/CoreBluetooth/Reference/AppleNotificationCenterServiceSpecification/Introduction/Introduction.html)、[AccessoryNotification](https://developer.apple.com/documentation/accessorynotifications/accessorynotification)、[Identifier](https://developer.apple.com/documentation/accessorynotifications/accessorynotification/identifier-swift.struct)。

### 最小语义模型（没有正式编码）

```text
NotificationComponentState [ESP32-owned, RAM only]
  availability: off / waitingForAuthorization / waitingForRide / ready / unavailable
  rideDisplayEpoch: 来自真实 AppModel Ride 生命周期投影的显示作用域
  ancsEpoch: 当前订阅 session（与 BLE/v1 session 分开）
  allowlist / privacyMode
  items[0…10]: 按真实 Added 顺序，仅当前 Ride 的未查看项目
  unreadCount: retained items 的计算结果，显示 9+
  centerOpen / selectedItem: 用户明确打开产生的 display state

AccessoryNotification [ANCS-backed]
  key: owner bond + ancsEpoch + NotificationUID
  sourceIdentifier?, sourceDisplayName?
  title?, subtitle?, messagePreview?
  sourceDateRaw?, receivedAtMonotonic
  categoryID, eventFlags
  positiveActionLabel?, negativeActionLabel? （对应 flags 才有效）
```

10条、9+为待验证产品上限提案，不是 ANCS 限制。discardedOlderCount 如要呈现必须由实际淘汰行为产生，不能展示虚构 total。现阶段不需要通用 Notification Event Bus、历史数据库或跨平台 provider abstraction。

获取策略：仅在真实 Ride scope 有效时保留新通知；Added 先取来源做筛选，列表打开时按需取标题及摘要。ANCS Control Point 请求串行、按 requested attribute tuples 重组 Data Source；解析未知、空、缺失、跨 MTU片段、过长 tuple、通知中途 Removed 和 error code。规格建议 lazy fetching；先订阅 Data Source，做好接收状态，再订阅 Notification Source，避免初始事件抢跑。[ANCS 服务与 sessions](https://developer.apple.com/library/archive/documentation/CoreBluetooth/Reference/AppleNotificationCenterServiceSpecification/Specification/Specification.html)。

### Ride / read / reconnect 语义

1. Ride inactive：不保留列表，不取 title/message；默认停止内容消费。ANCS off 与连接仍可供 Navigation 使用。
2. Ride active：真实 allowlisted Added → 本地 unread。paused 仍属于现有 Ride（`RideSession.isActive` 包括 paused）；建议保留列表但只显示 indicator，暂停不创建另一次 Ride。
3. 打开 Center 不自动把所有项目标 viewed；只有实际展示了某条的 source/title/preview 才移出 unread。选中项可短暂保持，关闭即释放。没有正文时不声称“已查看正文”。
4. 系统 Removed：立即从 unread / detail 移除，释放对应缓存。Modified 更新当前项，不能重新变 unread。
5. End Ride、自动 Ride rollback、用户关闭通知、撤权、换 owner、BLE/ANCS session 结束：清空正文、标识符、actions、字形内容缓存及 open-center state。End Ride 清空不调用 iOS dismiss，不删除系统通知。
6. ANCS 新 session 必须丢弃旧 UID/data。系统尽力补发既有通知，不是完整同步；建议忽略 `PreExisting` 通知，避免开骑/重连把历史通知当“本 Ride 新 unread”。断连期间的漏通知不能承诺恢复；这一取舍须产品确认。

当前协议没有独立真实 Ride lifecycle 消息；不能从 speed page、Navigation active、Backtrack flag 或 BLE session 猜测 Ride。8B需要一个小的 Ride display context 投影，若真实 Ride 尚无 start-time UUID，则使用显示作用域 token；它是去重/清空 identity，不是第二个 Ride 生命周期。授权且当前 App context 有效才启用正文获取；App heartbeat/上下文失联时 fail closed，避免系统仍连着 ANCS 而附件误收已结束 Ride 的内容。

## Actions / Quick Replies

| 能力 | ANCS（推荐 V1） | 新框架（C） |
| --- | --- | --- |
| 本地 viewed / clear | **Supported**：只影响 Waymate 显示 | **Supported**：同样可本地清空 |
| invoke action | **Conditional**：只有 positive / negative flags 存在；取真实 label | **Conditional**：只对通知 actions 中给出的 identifier/type |
| 系统 dismiss | **Conditional**：没有通用 dismiss command；negative 不保证就是 dismiss | **Conditional**：`.dismiss` action 存在时发送对应 response |
| reply text | **Not available**：Perform Notification Action 只有 UID + ActionID，没有文字参数 | **Conditional**：`.textInput(placeholder:)` action 存在时 `NotificationResponse.userText` 可提交文字 |
| 配置五条 quick replies | **Not available**：配置本身不能创造发送能力；V1不加入此设置 | **Conditional**：将用户选定字符串用于真实 textInput action；不能保证微信/所有 App 通知都提供该动作 |
| Mark as read | **Not available** 作为通用 read API；正/负动作若含此语义也只能按来源实际 label | **Conditional**：来源提供相关 action；不是全局 read同步 |

ANCS 从 iOS8 增加动作；官方明确 action semantics 由系统决定，不能猜“positive=回复/接听”“negative=删除”。Perform action 没有 Data Source success payload；ATT write 成功不等于完成送达/处理，须处理 ANCS errors、后续事件与超时，UI不能假成功。跨连接绝不重播 actions。[ANCS Perform Notification Action](https://developer.apple.com/library/archive/documentation/CoreBluetooth/Reference/AppleNotificationCenterServiceSpecification/Specification/Specification.html)。

C 确实具有文本回应，不应因为 ANCS 无 reply 就写成整个 iOS accessory 生态都不支持。官方 response 流程要求附件加密回传、系统解密路由、provider `sendResponse`；没有真实 textInput action 就不显示 quick replies。[Responding to forwarded notifications](https://developer.apple.com/documentation/accessorynotifications/responding-to-forwarded-notifications)、[userText](https://developer.apple.com/documentation/accessorynotifications/notificationresponse/usertext)。

**推荐 V1 首次交付：badge + unread Center + 本地 viewed/clear；系统动作延后且默认关闭；不提供五条文本回复。**

### Calls

ANCS 有 IncomingCall、MissedCall、Voicemail categories，官方举例说明来电 positive/negative 可接听/拒绝，但这是条件示例。FaceTime / 第三方 VoIP 若由系统生成相应通知可能出现，不保证分类、标题或相同动作；应在目标 App/OS 实测，不把“普通 App 能用 CallKit”当通知读取替代通道。[ANCS categories](https://developer.apple.com/library/archive/documentation/CoreBluetooth/Reference/AppleNotificationCenterServiceSpecification/Appendix/Appendix.html)、[CallKit 用于 App 自己的 VoIP 服务](https://developer.apple.com/documentation/callkit)。

C 具有 `AlertingContext.Kind.incomingCall`，也不保证每个 VoIP provider 的控制动作。[AlertingContext.Kind](https://developer.apple.com/documentation/accessorynotifications/alertingcontext/kind-swift.enum)。V1可以将真实 call event 当普通 badge（或排除来电）；不自动覆盖导航，不做 ringing screen、音频路由或通用接听按钮。未来电话需要独立交互/安全审计，8A不设计 Call Component 或 emergency priority system。

### Voice readout

V1交给 Siri / system Announce Notifications。系统可按 App 控制，部分通知可语音回应；官方支持特定 AirPods / Beats，不代表任何头盔蓝牙耳机都能自动播报。[Apple Announce Notifications](https://support.apple.com/en-us/102536)。ANCS B 的正文在 ESP32，App 若要朗读需再传回文本、增加敏感内容链与 audio session 冲突；现有 ESP32-S3 BLE 链也不是头盔 A2DP/HFP 音频桥。未来若考虑 Waymate speech，另行验证耳机、导航提示混音、锁屏与撤权，不在8A实现。

## Chinese / Emoji

### 当前资源的硬限制

两份 Noto SC 16/28 px 生成资源的 cmap `list_length = 110`，与 `scripts/generate_fonts.sh` 的去重字符一致，4 bpp、未压缩；是固定 UI子集。源 TTF **10,589,076 bytes（约10.10 MiB）**，存在仓库用于再生成，当前固件没有把完整 TTF 链接或安装到字体分区。不能把“repo 有 Noto TTF”当成可显示任意微信/短信中文。

现有 board 配置32 MiB flash、8 MiB factory app、7 MiB SPIFFS storage；本次读取已有 build binary **1,425,152 bytes**，不是新构建结果或实际烧录/空闲验证。PSRAM已启用，board给 LVGL额外2 MiB pool；本次没有测量实机剩余 heap / fragmentation。NimBLE内存仍配置 internal，不因有 PSRAM就没有 BLE资源限制。

现有 LVGL **9.5.0**，FreeType / TinyTTF / font compression 均未启用。仓库 `lv_binfont_loader.c` 约409行分配整个 glyph bitmap 到 LVGL RAM；当前 headers 没有在线新版 `dynamic_glyph_load` 功能。**不能引用最新网站说明就把数 MiB字体整体加载进现有2 MiB pool。** [当前字体说明](../shared/nav_ui/assets/fonts/README.md)、[实际 loader](../third_party/lvgl/src/font/binfont_loader/lv_binfont_loader.c)、[LVGL 官方 binfont 说明（须与仓库版本比对）](https://lvgl.io/docs/open/main-modules/fonts/binfont_loader)。

### 方案比较

| 方案 | Flash / PSRAM | BLE / latency / rendering | 许可、emoji和结论 |
| --- | --- | --- | --- |
| A 大范围 CJK bitmap 入 flash | 一个正文字号，glyph按需读取；不能每字号重复全文库，也不能全部进RAM | 无每通知字形传输；使用现有 LVGL fmt_txt 模式最接近当前链 | Noto OFL 可随资源分发并保留notice；不包含完整emoji。**V1首选**，先离线测真实生成体积 |
| B iPhone 动态 rasterize glyph | 附件小 glyph cache，phone生成字形 | B路线文本先到ESP32；必须请求 phone 渲染缺字（发送码点/cluster）。增加 request/response、cache/epoch、离线依赖 | 单码点不能正确处理ZWJ/combining/shaping；按cluster渲染。用可分发字体，Apple字体/emoji不默认当可复制资源。**可行但非最小V1** |
| C iPhone text → bitmap strip | 附件仅短图像，例360×32，4bpp为5,760B；RGB565为23,040B | B路线需要附件把已获授权文本回传给App再收图像，App后台可用性和额外隐私链成为条件；C路线需遵守官方密文/附件解密约束 | 能由平台布局处理emoji，但传输、license与失联fallback必须另审。**不作为默认方案** |
| D 外部字体资源（flash filesystem/mapped partition/SD） | 可隔离大字体与app；小cache或直接映射，资源版本必须匹配 | file IO/rasterizer增加延迟；当前没有完整字体挂载链 | 当前原始TTF >7MiB storage，不能直接装入；不要假设整TTF能塞现有pool。A的partition形态可作为后续升级；SD硬件未审计 |
| E 常用几千字 + fallback | 小资源，生成最简单 | fast，但姓名/生僻字/繁体会缺失 | 正文可能失真；只能作为明确coverage的降级，**不满足任意通知中文可靠展示** |
| F ESP32 本地TTF rasterization | TTF需字体存储；TinyTTF/FreeType需启用，bounded glyph cache | 正文到附件后可自行渲染；CPU、heap、字体解析边界需测量 | 不需手机回传内容；成熟库优先，但不自动解决全部shaping/color emoji。**A容量过大时的第二候选** |

不能把B/C的“iPhone发图片”当无条件绕过ANCS内容位置：普通App先拿不到他App通知。也不能用C官方forwarded内容向普通App回传来搭出另一条plaintext通道而忽略该框架限制。

### 容量与时延估算（分析，不是 benchmark）

粗略以方形glyph 4bpp、不压缩计算：21,000个基本CJK字 × 24×24×0.5 ≈ **6.05 MB** bitmap；28px约 **8.23 MB**。30,000字 ×28×28×0.5 ≈ **11.76 MB**。这些数不含glyph descriptors、cmap、标点与对齐，真实字形box也不完全等于字号，必须以converter最终binary / linker map测量。1个字号即可先验证；16/24/28各复制一份会很快超预算。

当前8MiB app剩余的表面空间约6.64MiB，只是旧build大小计算；不能预判完整24px字库一定塞得下。推荐先离线生成广覆盖Noto bitmap，测24/28px的实际大小、字形边界和缺字列表，再决定是否链接到app或使用版本化专用font partition。改变partition需要明确资源迁移步骤，不能覆盖NVS bond keys。资源放外部flash仍要有renderer；不是“有文件就能渲染”。

360×32 A4 strip=5,760B，超当前4,096B logical message cap；至少拆为两个bounded assets/messages，185 MTU时纯数据最低34帧（每帧170B应用payload），默认23 MTU约720帧（每帧8B）。RGB565是135/2,880帧，均未计metadata/ACK。假设真实有效应用吞吐10KB/s，A4 strip纯传输约0.58s，RGB565约2.3s；此速率仅用于预算示例，不是Waymate已测吞吐，还要加ANCS fetch、phone wake、rasterize与调度时间。

相比之下30个常见汉字glyph按28px/4bpp约11,760B，传glyph未必比一行bitmap省。A本地字体只传文本/索引，最适合ANCS direct与导航优先。

**8B字体验收定义：** 审核基本CJK、繁体、标点、Latin、常见日文/混排与姓名样本；支持范围按实际cmap声明，其他scripts、扩展区和shaping不能承诺完整Unicode。缺失始终显式显示replacement，并提示“部分字符不可显示”；不能静默删字后把残缺正文当完整。若不能达到目标中文覆盖，退到badge/source模式，不交付假中文Center。

### Emoji

ANCS发UTF-8文本；当前Inter/Noto子集不支持😂/❤️/👍/🚗的完整emoji表现。emoji有variation selectors、skin-tone、ZWJ组合，不能按字节或单码点吞掉其中一部分。[Unicode Emoji](https://www.unicode.org/reports/tr51/)。

V1推荐：**unsupported grapheme cluster用一个明确的replacement图形**，可提示“含未支持表情”；不静默忽略，不假称支持彩色emoji。少量有许可的monochrome图形可在下一轮按准确sequence单独纳入，但不是整套emoji。Color bitmap transfer成本最高，留作后续。Replacement会损失情绪/语义，故圆屏只做preview，需要用户回手机确认；不可据残缺emoji生成动作判断。

### 长文本 truncation

候选读取上限：title 96B、subtitle 96B、message 192B、app identifier 128B、display name 64B；属于Waymate parser/UI预算，不是Apple限制。ANCS仅title/subtitle/message带请求max length；其他属性仍需处理16-bit长度和有界存储，超限丢弃/跳过，不写坏缓存。

UTF-8字节上限只决定接收预算。呈现采用一行source、一行title、一行preview，按实际glyph宽度裁切，分别最多约12/12/14个user-perceived grapheme clusters（最终以圆屏字号/safe area验收为准），末尾使用确实包含在字体中的 `...`。先验证UTF-8，删掉截断产生的不完整尾序列；组合字符/emoji按cluster边界处理，不用 `substring(0,N bytes)`。newline/tab归一空格；控制字符不执行/不显示。协议按bytes记录长度，显示按pixels/graphemes。[Unicode text segmentation](https://www.unicode.org/reports/tr29/)。

不自动滚长正文，不marquee、不自动翻页。收到长通知仍只加badge；用户主动看一行摘要，不把全部body铺满圆屏。

## Security

### 已有保护与真实缺口

当前 `ble_nav_transport_nimble.cpp` 请求LE Secure Connections、bonding，IO为NoInputNoOutput，`sm_mitm=0`。custom RX需要encrypted write，TX的notify permission需要encryption，`notify_frames`也检查connected/encrypted/subscribed。CRC16、ACK、sequence不是加密或身份认证；本机sdkconfig仍允许legacy pairing，`sm_sc=1`不证明每次最终bond都用了SC。

这是已有加密，不是明文广播。广告只含服务/名称，没有通知内容。**但Just Works没有MITM认证；MAX_BONDS=3、general advertising、repeat-pair自动删除peer并retry，不等于只允许唯一机主。** 新近设备首次接入/替换bond与通知数据归属需要更严格准入。

旁边未授权手机不能通过ANCS读“原iPhone”的系统正文：iPhone有自己的bond/consent检查。但当前firmware不能据“任意加密连接”确认是正确Waymate owner；若后续把缓存正文返给App或发送raster请求，可能在换owner后泄露残留。应将通知session绑定真实bond peer identity / IRK，不使用“WAYMATE”名字、临时RPA或自定义session ID作为所有权。

### V1必要的最小加固提案

1. Notifications OFF默认；机主明确开启/批准pairing window；绑定一个通知owner，已有owner下不静默接受替换bond。若采用passkey/numeric comparison，需要利用当前触屏设计可审查的配对UI；是否升级到MITM认证由8B.2验证，不能声称现有Just Works已达到此等级。
2. 访问内容前同时检查encrypted、bonded identity、iOS ANCS authorization/成功订阅、用户设置和有效Ride context。SC协商结果需读取真实`sec_state`确认。
3. repeat pairing失败、失去encryption、ANCS撤权、Service Changed撤下服务、owner变化立即隐藏/清空内容。手机端`ancsAuthorized`回调是补充，不把App进程存活作为唯一撤权检测。
4. 列表、正文、date、actions、临时bitmap仅RAM；不进Ride history/GPX/share cards、NVS、analytics、cloud或debug logs。buffer生命周期结束释放/清理；释放allocator内存不等于可靠抹除所有底层副本，应尽量缩短寿命。
5. 正文不advertise；diagnostic只记录状态、错误码和容量，不打印文本/来源隐私详情。用户“Clear Waymate”不发送系统dismiss。lost ACK不重放已执行系统动作；cross-epoch命令直接拒绝。

本轮没有调整security layer、刷机、删除bond或开启系统通知授权。上述是正式通知内容上线前的门槛，不是把整个BLE subsystem重写的要求。配对/保留keys的官方要求见 [附件指南 §58.8–58.10，p.353–354](https://developer.apple.com/accessories/Accessory-Design-Guidelines.pdf)。

## UX Model

### Privacy-first 的三档风险

| 默认圆屏内容 | 泄露/骑行风险 | 判断 |
| --- | --- | --- |
| A App + sender/title | 名称可透露联系人、关系与敏感App；title不一定是sender | 只在主动查看时，并仍允许隐藏title |
| B App + title + preview | 可能泄露验证码、账户、医疗等正文；增加阅读负荷 | 主动进入Center后的一行摘要，用户可关闭preview |
| C icon / unread | 最少内容，但仍泄露“有消息”和计数 | **骑行主屏默认**；也提供完全OFF |

不把验证码/金融/医疗内容的正则过滤称为可靠保护；source类别不充分，默认内容最小化比猜测敏感正文可靠。

### Primary Page + Notification Layer

```text
既有 Primary Page：Navigation / Backtrack / Ride / Media / Idle
                    +
独立 Notification Layer：hidden / badge / 用户主动打开的 Center
```

不新增Coordinator primary enum，不把通知伪装Navigation/Media，不调用 `manuallySelect` 将Center作为同等级page。未来最小改动是在shared UI screen上加独立layer及少量notification state setters，由现有render task消费ESP32 NotificationComponentState；Primary Page继续在其下更新。`NavPresenter`保持导航语义，通知标题/body不进入`NavSnapshot`。

到达只改变unread badge，不改变page、不show全文、不打开Center、不使用Urgent frame flag。indicator在安全区高对比显示通用图标+bounded count，true black背景，不遮maneuver距离、方向、离路线/轨迹提醒或route图。

用户点indicator或专用明确gesture打开Center；建议局部向上/下分页查看最多一条或两条short items，返回gesture关闭。现有水平swipe继续表示Primary Page浏览；Center打开时仅由局部layer接管其手势，避免gesture bubbling同时触发底下page。关闭恢复**此时**Driver选定page，不缓存旧page强行跳回。

off-route、rerouting、Backtrack off-track等既有紧急状态来到时立即收起Center，保持badge；maneuver信息永远保持可见，Center宜用局部面板，不覆盖核心导航区。若未来设计全面板，需要真实 maneuver active信号/既有导航状态阻止遮挡，不能自行用距离阈值发明urgent policy。用户操作/打开Center不得延缓导航最新数据渲染。

Notification Layer需要自己的纯显示状态，但不需要另一套Primary Page策略。电话/ANCS Important/CategoryID不创建新的emergency priority system。普通通知一律badge。

## BLE Protocol Impact

### Option B 的最小 additive scope

**通知正文不需要 phone→ESP32 NotificationState/Event 传输：它们从系统ANCS直达附件。** 但当前Ride作用域和筛选/privacy设置在iPhone，现有协议没有这些语义，仍需最小control plane扩展：

| proposed message（未分配wire ID） | 内容/方向 | 需求 |
| --- | --- | --- |
| NotificationDisplayContext | phone→device：display scope token、真实inactive/active/paused投影、enabled、privacy mode、allowlist revision / 有界来源列表、validity lease | 真实Ride/设置同步；结束token清空，不能以page推断 |
| NotificationAvailability | device→phone：可用/授权待定/失败、context revision、实际unread count；不带正文 | 可选用于设置诊断；不能把metadata ACK当通知已读 |
| Local viewed / clear / center controls | ESP32内处理 | 不需要转成phone DeviceCommand；不经phone中转执行ANCS action |

capability按旧peer negotiated支持才发送，IDs/bits留待8B协议审查，保持现有UUID/layout/version兼容。allowlist最多候选10来源，每identifier≤128B，约1.3KiB加header，仍需总message cap验证；配置ACK后原子生效。Context更新幂等，clear必须有scope/generation tombstone，旧消息不能复活清空列表。

ACK表示ESP32接受display config/context，不表示系统通知收到/读过；context refresh失联则停止内容fetch。首次Ready和重连重新发最新context及设置，再恢复ANCS的本session状态；不重播view、dismiss、positive/negative或reply。优先发navigation/backtrack baseline，普通通知不得占用其发送预算。

### 如果未来选A（仅自有通知）或C

候选语义为NotificationState（metadata snapshot）、NotificationEvent（add/update/remove）、NotificationAction（按给出的action标识）、NotificationDismiss（先区分本地clear和系统dismiss），或BoundedTextAsset。它们只在确有经过授权的数据源时成立；C必须承载官方transport密文与session semantics，不能把本文普通event payload当官方security替代品。

现有GATT推荐MTU185，frame最多182B，header10+CRC2，应用payload最多170B；默认MTU23时20B frame仅8B payload。logical message默认上限4096B，一方向只接受一条in-flight重组消息，默认fragment timeout1000ms。大通知/bitmap不能与navigation fragments任意交错；ACK/backpressure/优先级须按当前write pump执行，不能无限queue。

若需普通UTF-8 event，候选上限source64B、title96B、preview192B，加identity/action metadata应保持单条≤512B；保留明确byte lengths，不经Media字段（当前Media source31B、title63B、artist47B）偷渡通知。多条通知逐条有界发送，不把全部Center做超大snapshot；atomically update后ACK，用scope+event revision去重，重连重发最新metadata，不重放action。中文每常见字约3B、emoji常4B且可能多scalar，先合法UTF-8再按cluster/pixels裁切。

B直接ANCS的8-byteNotificationSource和ATT fragmentation不含Waymate的12B frame开销；两种transport解析器必须分开，不能把ANCS DataSource喂给v1 reassembler。

## Recommendation

**V1选择Option B：Direct ANCS accessory，单BLE link，ESP32本地Notification Layer/Center，广覆盖本地bitmap字体，一个正文字号，unsupported emoji显式replacement。**

原因：公开官方BLE服务；无需普通App越权；无新增通知entitlement/MFi门槛；全球DIY更容易复现；text小、无需bitmap往返；通知到达不改变已有Primary Page。代价是系统级按App筛选和自定义quick replies不可用，通知source/text受平台隐私状态约束，中文不是任意Unicode保证。

Waymate应准确说“选择在Waymate显示的来源”，而非“授予每个App的系统通知权限”。V1先交付badge与主动Center，source/title/一行preview；默认不开系统动作和朗读。**不让“功能候选存在”升级为“已验证生产链”。**

## Stage 8B Plan

以下仅为待授权实施计划。本轮未开始任一步骤。

| 阶段 | 最小工作 | 验收/停线条件 |
| --- | --- | --- |
| 8B.1 ANCS Proof of Concept | 隔离firmware分支/实验目标；在一个NimBLE host/同一conn_handle开启GATT client（满足IDF central Kconfig依赖）；service-changed、发现/subscribe、限量真实通知解析；phone按需加ANCS consent options | 实机证明custom Navigation数据与ANCS同时工作；首次允许/拒绝、复配、撤权、锁屏、App终止、物理重连。只能用主动产生的真实通知；不打印私人正文。失败即停，不自动多连接重构 |
| 8B.2 BLE / security | 唯一notification owner、明确pairing window、repeat-pair保护、bond identity、content清空、实际encryption/SC结果检查；评估MITM认证UX | 陌生phone不能接管/读缓存，撤权/换owner/失联立即hide/clear；旧epoch数据/actions不能被采用 |
| 8B.3 Context / data model / font gate | 使用真实Ride投影与幂等display scope；bounded ANCS parser、allowlist、10-itemRAM队列、lazy fetch；先离线生成大范围单字号CJK并测binary/heap/license | EndRide/rollback/paused/失联行为明确；Modified/Removed/PreExisting/error可处理。真实中文coverage/容量不达标则保留badge/source，不开preview |
| 8B.4 Notification Layer | 现有render task提交独立badge/center layer；Coordinator policy保持；只手动打开 | 所有Primary pages都可indicator；到达不抢屏；urgent提示收起Center，maneuver核心可见；swipe无重复事件 |
| 8B.5 Round Display Center | source、原始title、一行boundedpreview、本地viewed/clear，覆盖任意输入/缺字/emoji fallback | 中文/繁体/缺字/组合emoji、最大10项、长文本、真实锁屏preview限制；清空不改变iOS系统Center；不长文滚动 |
| 8B.6 Actions（独立可选gate） | 仅实测带positive/negative flag和真实label的通知；单次明确操作，超时/错误显示真实结果 | 不重放、不猜语义、不提供文本quickreply；来电先逐provider验证。若V1需求不强，可直接延后 |

8B最终验收需同时保留已有Nav/Ride/Backtrack/Media测试，并在实际iPhone+ESP32上测持续导航、通知突发、锁屏、断连、结束Ride后清空、内存高水位与画面。NativeUI/SDK probe/firmware build不能替代这些实机结论。

## Risks

| 剩余风险 | 当前证据边界 / 处理 |
| --- | --- |
| 单连接ANCS共存 | 官方角色/GATT规格与本机NimBLE APIs支持设计；当前固件未启用/实测client。8B.1是硬gate |
| 新iOS系统行为 | R31仍列ANCS，本机18.5 symbols可编译；未跑iOS26/27设备。必须记录具体OS/硬件版本 |
| Focus/锁屏preview/敏感内容 | ANCS按系统提供字段；缺失合法，不保证微信/短信始终返回title/body。需要真实授权/锁定状态矩阵 |
| ANCS session不完整同步 | UID session-scoped；断开清空、PreExisting忽略会漏掉gap中的通知。V1按当前Ride实时通知定位，不做全系统history mirror |
| EndRide时App不可达 | 系统ANCS可比App活得久；context lease失效停内容fetch，不能依赖最后page/active flag永久有效 |
| 机主身份 / MITM | 已加密+bond，但Just Works无MITM、多bond/复配策略需收紧。正式正文上线前处理 |
| 字体容量/Unicode | 110固定glyph不适用；local大范围字库需生成测量。不能承诺全部Unicode/emoji、不能整体加载数MiB字库入现有pool |
| 用户过滤理解 | B只是display filtering，系统先向附件传metadata；公开说明差异，未知来源默认隐藏 |
| C entitlement资格 | 公开文档未证明Personal Team/人工审批结论，本机SDK不具备；不要据Portal旧beta投诉推定当前状态 |
| UI骑行安全 | badge成本低；Center只主动、短文本、maneuver可见、urgent立即回主屏。无新call/emergency抢占 |
| 协议兼容与调度 | unknown enum会被旧codec拒绝，需capability gate；largeassets不能占满单in-flightreassembler和RXqueue |

若8B.1失败或8B.2/字体gate无法达到V1标准，降级顺序：**badge/source-only（仍需ANCS真实事件与来源支持）→ Waymate-owned提示 → V1暂不提供通知**。Incoming-call-only并不免除ANCS权限/连接验证，不能作为保证成功的捷径。Android notification listener可作为另一个平台的未来独立审计，非本轮已核实能力；未来欧盟C或认证附件是另一产品分支，不以此硬补当前V1。

## Validation Evidence

### 本机 SDK probe

throwaway 文件仅在 `/private/tmp/waymate-stage8a-probe/`，未接生产代码、未触发蓝牙连接、未请求通知权限：

```swift
import CoreBluetooth
func authorization(_ p: CBPeripheral) -> Bool { p.ancsAuthorized }
let connectOptions: [String: Any] = [CBConnectPeripheralOptionRequiresANCS: true]
final class Delegate: NSObject, CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {}
    func centralManager(_ central: CBCentralManager,
                        didUpdateANCSAuthorizationFor peripheral: CBPeripheral) {}
}
```

执行：

```sh
xcrun swiftc -typecheck \
  -sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS18.5.sdk \
  -target arm64-apple-ios17.0 \
  -module-cache-path /private/tmp/waymate-stage8a-probe/cache \
  /private/tmp/waymate-stage8a-probe/ANCS.swift
```

结果 **exit 0**。本机headers位置：`CoreBluetooth.framework/Headers/CBCentralManagerConstants.h:146`、`CBPeripheral.h:110`、`CBCentralManager.h:388`，均 `NS_AVAILABLE_IOS(13_0)`。

独立 `import AccessoryNotifications; import AccessoryTransportExtension` typecheck结果 **exit 1**，`no such module 'AccessoryNotifications'`；SDK目录另外核对两个新framework均不存在。这是环境能力缺失，非Waymate回归。未编译iOS26.5 SDK probe，也未做新extensions的签名验证。

### 文档/仓库检查

- Apple官方DocC JSON保存在 `/private/tmp/waymate-stage8a-apple/`，读取metadata.platforms及actual symbols；URL模板为 `https://developer.apple.com/tutorials/data/documentation/<path>.json`。SDK/header availability与在线文档availability分列，没有混写。
- Apple官方附件指南R31下载并定向读取§58；p.355已render/目视核对，页脚日期2026-09-21。未用2014 ANCS archive发布日期推断当前停用。
- 配置、transport、bridge、presenter、page/gesture、font cmap、现有binary和本机IDF Kconfig/API均为只读检查。
- 本轮不跑生产测试/完整build：没有生产变更；SDK probe只证明symbols可typecheck。未刷机、未发真实通知、未访问用户系统Notification Center内容。

## Sources

访问日期均为2026-10-08；以下Apple平台结论优先使用官方资料，论坛和新闻没有作为关键资格/能力依据。

| 来源 | 定位/支持内容 |
| --- | --- |
| [Apple Accessory Design Guidelines R31](https://developer.apple.com/accessories/Accessory-Design-Guidelines.pdf) | 2026-09-21；§58.1 p.350 role；§58.8–58.10 p.353–354 privacy/pairing；§58.12.4 p.355 ANCS当前服务；§58.14 p.355–356系统GATT/过滤/ServiceChanged |
| [Apple Bluetooth](https://developer.apple.com/bluetooth/) | 当前仍链接ANCS规范；CoreBluetooth/ExternalAccessory区分 |
| [ANCS Introduction](https://developer.apple.com/library/archive/documentation/CoreBluetooth/Reference/AppleNotificationCenterServiceSpecification/Introduction/Introduction.html) | NP/NC、GATT依赖、UTF-8 |
| [ANCS Specification](https://developer.apple.com/library/archive/documentation/CoreBluetooth/Reference/AppleNotificationCenterServiceSpecification/Specification/Specification.html) | service/characteristics、attributes/fragmentation、actions、session lifetime、lazy fetching、errors |
| [ANCS Appendix](https://developer.apple.com/library/archive/documentation/CoreBluetooth/Reference/AppleNotificationCenterServiceSpecification/Appendix/Appendix.html) | categories、event flags、attribute IDs、date字符串、两个ActionID |
| [CoreBluetooth RequiresANCS](https://developer.apple.com/documentation/corebluetooth/cbconnectperipheraloptionrequiresancs) / [ancsAuthorized](https://developer.apple.com/documentation/corebluetooth/cbperipheral/ancsauthorized) | 普通companion App的授权API；本机headers/compile补充availability |
| [WWDC19 Core Bluetooth](https://developer.apple.com/videos/play/wwdc2019/901/) | transcript accessory notifications段；iOS13授权prompt、配对/连接后contextual prompt、Bluetooth settings |
| [UNUserNotificationCenter](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter) | 自己App/extension的notifications范围 |
| [AccessoryNotifications](https://developer.apple.com/documentation/accessorynotifications) / [AccessoryTransportExtension](https://developer.apple.com/documentation/accessorytransportextension) | 当前iPhone/EU限制；DocCintroducedAt 26.5/26.2 |
| [Receiving iOS notifications on an accessory](https://developer.apple.com/documentation/accessorytransportextension/receiving-ios-notifications-on-an-accessory) | ASK、三extensions、entitlements、Bluetooth、HPKE和数据组织 |
| [Data provider entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.accessory-data-provider) / [Security entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.accessory-transport-security) / [Transport entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.accessory-transport-extension) | key、boolean true、extension要求与introducedAt |
| [Supported iOS capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-ios/) | 账号能力参考；未提供新三项PersonalTeam明示结论，不能作已批准证据 |
| [AccessoryNotification](https://developer.apple.com/documentation/accessorynotifications/accessorynotification) / [Identifier](https://developer.apple.com/documentation/accessorynotifications/accessorynotification/identifier-swift.struct) / [Alerting kind](https://developer.apple.com/documentation/accessorynotifications/alertingcontext/kind-swift.enum) | 实际可选字段、identity、incomingCall |
| [Responding to forwarded notifications](https://developer.apple.com/documentation/accessorynotifications/responding-to-forwarded-notifications) / [userText](https://developer.apple.com/documentation/accessorynotifications/notificationresponse/usertext) | 官方有textInput回复、dismiss/background动作、加密返回链；不是ANCS命令 |
| [Internet transport](https://developer.apple.com/documentation/accessorytransportextension/forwarding-notifications-to-your-accessory-using-the-internet-transport-type) | 同一新框架的官方网络扩展，非普通App越权方案 |
| [Xcode requirements](https://developer.apple.com/xcode/system-requirements) | Xcode与SDK实际版本对应 |
| [MFi FAQ](https://mfi.apple.com/en/faqs) / [QA1657](https://developer.apple.com/library/archive/qa/qa1657/_index.html) | 普通BLE/CoreBluetooth附件非MFi；ExternalAccessory区别 |
| [Apple Developer Program Agreement](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/) | 新框架ForwardingInformation用途、远端保存和附件/设备内容传递约束；未来实施需核对当时原文 |
| [Apple Siri announcements](https://support.apple.com/en-us/102536) / [CallKit](https://developer.apple.com/documentation/callkit) | 支持耳机/应用的系统播报；CallKit非全局通知读取替代 |
| [Espressif NimBLE v5.5.5](https://docs.espressif.com/projects/esp-idf/en/v5.5.5/esp32s3/api-reference/bluetooth/nimble/index.html) | 本机相同IDF系列；client Kconfig依赖和API另以实际本机源码核实 |
| [LVGL fonts/binfont](https://lvgl.io/docs/open/main-modules/fonts/binfont_loader) | 外部字体文件不等于TTF/无RAM成本；当前仓库loader检查优先 |
| [Unicode UAX29](https://www.unicode.org/reports/tr29/) / [UTS51](https://www.unicode.org/reports/tr51/) | grapheme truncation与emoji sequences |
| [字体资源/notice](../shared/nav_ui/assets/fonts/README.md) / [Noto OFL](../shared/nav_ui/assets/fonts/licenses/NotoSansSC-OFL.txt) | 原始字体许可与生成范围；不借此保证Apple系统font/emoji可再分发 |

## Git Status

开始状态（完整 `git status --short --branch`）：

```text
## main...origin/main
?? design/
```

交付状态（本报告为唯一仓库新增文件）：

```text
## main...origin/main
?? design/
?? docs/Waymate_Stage_8A_Notifications_Feasibility.md
```

tracked与staged diff均为空；本报告未stage；HEAD未变。`design/`是原有untracked目录，本轮未读写其内容。临时下载、PDF渲染和compile probe在 `/private/tmp`，没有接入生产或加入仓库。没有commit/push；没有开始Stage8B。
