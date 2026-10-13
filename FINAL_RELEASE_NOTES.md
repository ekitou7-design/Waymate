# Waymate 0.3.2 Final RC2

> 本文保留 2026-10-12 RC2 交付时的构建与安装记录；其中“未 commit / push”等表述指交付阶段。后续 GitHub 源码整理与复验见 [GITHUB_SOURCE_RELEASE.md](docs/final/GITHUB_SOURCE_RELEASE.md)。

**READY FOR DEVICE TESTING** · 2026-10-12 · iOS 0.3.2 (8) · ESP32 `0.3.2-final-rc2`

本候选完成比赛前的 Demo、导航布局和 README 收敛。软件验证通过，可用手机模拟器独立录屏；当前候选尚未安装到真实 iPhone 或圆屏。比赛实机展示需先按验收清单完成设备测试。

## 最终导航

- 路线优先：黑底、粗白路线、明显的当前位置箭头、下一动作距离、辅助转向图标、中文方位和底部进度弧。参考用户提供的 Beeline Moto II 导航图布局，使用项目自己的 LVGL / SwiftUI 绘制，没有复制其图片、字体或品牌素材。
- 真实导航：既有 NavCore 路线窗口（最多 24 点）→ BLE v1 RouteGeometry → PhoneNavBridge → 共享 Presenter → LVGL。演示使用同一生产链路，只替换输入。
- 手机预览和圆屏共享 466px 地理投影；地图朝上来自附近的规划路线段，不依赖 IMU 或手机朝向。转弯处存在方向歧义时保持先前视角；新路线缺乏可靠方向时采用北向上。该展示计算不替代 NavCore 路线匹配。
- 连续缩放：距离较远显示长段，靠近路口聚焦；既有 LVGL 25ms 插值复用。未承诺真机 40 FPS，物理显示帧率待测。
- 手机正式导航保留 Apple 地图底图、完整规划路线、当前位置、指令、剩余距离和时间，以及“路线总览”。完整底图不是微型路线示意图；底图可用性仍取决于系统地图服务和缓存。
- 路线几何缺失时显示 `ROUTE UNAVAILABLE`，保留可靠转向和距离；未知动作不造箭头／距离；偏航、定位失效、重规划隐藏实时路线指引并显示状态。
- 周边道路只画已有真实数据；没有数据时留空，不补画虚构路口。未添加示例限速牌。

## Demo

“更多 → Demo Mode · 演示模式”，默认关闭。84 秒脚本涵盖模拟规划、Navigation、Ride、Backtrack；支持开始、暂停、继续、重播、下一步、三阶段跳转、退出，以及左右转、直行、连续弯道、掉头场景。

每个场景的路线、模拟位置、速度、记录轨迹和返回距离均来自自己的固定几何。Demo 使用独立内存 NavCore / Ride / Backtrack，会话不能触及定位服务、真实存储或用户偏好；正式会话进行中禁入演示。退出丢弃模拟会话并重新同步正式展示。

手机始终标明 `DEMO / 模拟演示`、`模拟圆屏 / DEMO PREVIEW`，BLE 连接状态保持真实。兼容标记使用既有道路名称字段 `WAYMATE DEMO`；最终固件显示 DEMO，旧固件可能显示该文本或不显示新角标。旧固件展示不是最终 UI 验收。

## 软件验证

| 验证 | 结果与范围 |
| --- | --- |
| ESP-IDF 5.5.5 完整隔离构建 | PASS；编译输入 2024 项均来自本候选、SDK 或本次生成文件 |
| Native CTest | 10/10 PASS；包含导航、Presenter、几何、协议、PhoneNavBridge、页面状态与 LVGL |
| iOS 单元测试 | 245/245 PASS；Navigation / Ride / Backtrack / History / Demo 隔离 |
| iOS Demo 界面 | 3/3 PASS；84 秒完整播放，控制与左转场景选择，退出恢复 |
| Swift Package | 19/19 PASS；MotoNavigationCoreChecks PASS |
| 字体、466px 边界 | PASS；真实 LVGL 渲染，A–F 场景、中文覆盖、圈外像素与无几何降级 |
| 启动／DMA 排空回归 | PASS；真实源码编译或提取后的硬件替身测试，失败路径锁释放及 BLE 时序 |
| 安装／回退逻辑 | PASS；离线模拟 Flash，App-only、NVS 一致性及错误拒绝。未连接串口执行 |
| iPhone Release 构建与签名 | PASS；0.3.2 (8)，同一 Bundle ID，开发签名，Profile 对一个已配置设备有效 |
| 静态／主机内存 | PASS；见 [RAM_REPORT.md](docs/final/RAM_REPORT.md) |
| `git diff --check` | PASS；未 commit / push |

测试是软件或模拟输入证据。当前实机 Internal RAM / PSRAM / 任务栈 / 首刷 / BLE 稳定性 / GNSS / 道路推进 / Ride / Backtrack **均未运行**。用户报告的三次冷启动及 BLE 成功属于此前 Display Startup Experiment，不能移作本候选的验收。

## 冻结与兼容

本次不修改 Ride / Backtrack 业务逻辑。保留此前 P0 未知动作与 NVS 不自动擦除修复，以及启动 DMA 排空和 BLE 初始化时序。与 Cardinal 源码基线比较，19 个受保护的启动、显示驱动、配置、Transport、协议与字体源文件 SHA-256 均一致。

BLE UUID、v1 版本、包结构、能力位、RouteGeometry 点数上限和分片规则均未改变；沿用旧编解码器与 golden fixture。只在既有 roadName 文本中放置保留演示标记。未引入 ANCS、Stage 9B PSRAM 实验或新图形框架。

## 构建产物

以下文件位于独立发布包，不自动写入仓库或设备。

| 文件 | 内容 |
| --- | --- |
| `Waymate_Final_RC2.bin` | 最终 App 镜像，1,441,424 字节 |
| `Waymate_Final_RC2.elf` / `.map` | 与该 .bin 匹配的符号和链接报告 |
| `Waymate_iOS_0.3.2_8_signed_App.zip` | 开发签名的真机 Release App，供手动覆盖安装 |
| `Waymate_Final_RC2_Source.zip` | 最终完整源码及第三方依赖，含 README 和许可证 |
| `Waymate_Final_RC2_All_Changes.patch` | 对 Git `76ee61d902cc278d00cf2625973c8ff3ac3ec97f` 的累积差异，含此前启动／P0 修复 |
| `Waymate_Final_RC2_Task_Changes.patch` | 相对此前 Cardinal 候选的本次功能差异 |
| `Rollback_Display_Startup_Experiment.bin` / `.elf` | 旧启动实验构建的匹配历史回退参考；并非本轮读取的设备镜像 |

最终 .bin SHA-256：`58bc503180f5ae84e2afeb2828404902da17ffadd1e37fb363393c4220799858`。ELF descriptor 内的 SHA-256 与交付 .elf 一致。其他文件见 `SHA256SUMS.txt` 和 `release_manifest.json`。

## 安装与回退

需要更新 iPhone App 才能使用 Demo、路线选择和手机新页面；需要更新 ESP32 App 固件才能在实体圆屏展示最终 UI 和 DEMO 角标。仅看手机预览不需要圆屏。蓝牙兼容性保持，但旧版配合不能作为新功能已部署的证据。

见 [INSTALL_AND_ROLLBACK.md](docs/final/INSTALL_AND_ROLLBACK.md)、[DEVICE_ACCEPTANCE.md](docs/final/DEVICE_ACCEPTANCE.md) 和 [RECORDING_GUIDE.md](docs/final/RECORDING_GUIDE.md)。本轮未刷写、未真机安装、未改 NVS / Bond、未覆盖原 ANCS 工作区、未 commit / push。

iOS 开发 Profile 到期：2026-10-19 09:03:18 UTC（北京时间 17:03:18），只覆盖当前配置的一个设备。签名 App 是本用户的本地安装产物；公开发布源码时不包含 Profile 或私钥。

软件录屏与设备测试准备已完成；实际提交视频、真实导航和端到端硬件验收需要用户录制并核实。冻结后仅处理阻断问题。
