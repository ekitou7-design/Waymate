# Stage B — 修改前 UI Audit

审计日期：2026-10-06。HEAD：`c171d04 feat: establish Waymate brand system`。
原有未跟踪文件：`design/waymate-icon-design.png`、`scripts/ios/generate_waymate_brand.swift`，不改动。
Stage A 的 Theme、W Logo、资产和 Launch branding 已存在。

## 当前页面结构

ContentView 用一个 NavigationStack，根据 AppModel 的 isNavigationActive / selectedPlace 推导路径。首页、路线预览、导航使用 insetGrouped List；设备 Form、离线地图、网关和数据说明使用 sheet。未使用 Tab Bar。

1. Idle：首页先放 Ride Section（Start Ride），然后网关设置、搜索、Recent / 空提示、Device、Offline Maps、明确标记的 Demo、隐私。主次不突出，缺少品牌 Hero。
2. Ride active：相同首页首部 Section 显示 elapsed / moving / distance / optional speed 与 Pause / End。TimelineView 的 1 秒更新已局限在指标区，无需新 timer。
3. Ride paused：状态文字和 Resume 改变，版式与 active 基本相同；未知速度显示 --。End 没有确认。
4. Route Preview：Ride Section 和目的地先于 270pt 地图，地图不是主要视觉；最多现有候选数由 provider 决定。候选含真实 ETA、距离、交通与选择 identifier。底部按钮可开始或重试规划；离线入口保留。
5. Active Navigation：Ride Section 优先于导航；显示通用 location 图标与 phase，未把 NavigationComponentState 的真实 maneuver / distance / road / instruction 展开。ETA 和 remaining 依赖接受路线，不检查位置 freshness；offRoute 与 stale 缺少独立醒目表达。
6. Device / BLE：真实 connection enum + negotiatedProtocol == V1 判定 ready。sheet 可连接/断开、查看位置权限；BLEDeviceSnapshot 还包含 lastCommandID 与失败关联 message，当前未展开。没有电量数据。
7. Media：AppleMusicRemoteController 使用 systemMusicPlayer，BLE 回调发送 PhoneMediaState；iPhone 没有入口，也没有 AppModel 公布的媒体投影。Coordinator temporary media 尚未生产接线。
8. Offline Maps：MapDownloadsView 保有城市查询、范围地图、路线走廊下载、进度、暂停、删除包、缓存清理。底图离线不等于离线路线规划，提示已明确。
9. 错误/loading/permission：搜索 progress / failure / 无结果 / location bias 与设置入口；route preview loading / failure；rideFailure；navigationFailure；BLE failure/unavailable；SurroundingMapStore 状态可查看。没有全局网络 reachability 数据，不能凭猜测显示 OFFLINE Hero。
10. Recent：AppModel 从 UserDefaults 加载真实最近搜索，最多 8 项，不需要示例地点。

## 已阅读的边界与主要问题

已阅读 ContentView 及其所有子 View（RouteOverviewMap、SurroundingMapStatusRow、MapDownloadsView 子页、GatewaySettingsView、DataUseView），AppModel、RideSession、NavigationComponentState、PresentationCoordinator、WaymateTheme / Logo、AppleMusicRemoteController，iOS AppTests / UITests 的测试范围、Ride/Navigation/Coordinator 关键测试实现和全部 UI identifier。

Stage A 只在部分控件使用 token；RouteOverviewMap 与离线范围地图仍有 system blue。Dynamic Type 已有部分纵向降级，但 List 的工程信息密度较高。NavigationStack 的 Back cleanup、真实搜索/provider/geometry、Ride 与 Navigation 独立结束语义必须保留。

## 修改前验证

Xcode 16.4；XcodeGen generate 成功；iOS 18.6 iPhone 16 Pro Simulator 可通过获准本机执行访问。完整 baseline AppTests + UITests 已启动，结果单独记录在最终报告。用户提供的 Stage A 已知记录为 16 项中 7 项地图/在线相关失败；不能把这条历史记录当成本轮精确结果。

## 实施范围

首页与 Ride 用滚动的品牌布局；Route Preview 地图优先；导航突出真实转向与 freshness/warning；设备统一状态行、诊断降级 sheet；Media 仅公开现有控制器投影与动作，不修改控制器。核心页面局部 dark 环境，辅助 sheet 保持自适应。轻量 End Ride 确认必须有取消及确认测试。无新状态机、provider、协议、生产假数据或 Stage C 工作。
