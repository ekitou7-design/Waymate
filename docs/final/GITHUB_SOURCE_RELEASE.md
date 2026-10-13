# Waymate RC2 GitHub 源码发布核验

整理日期：2026-10-13。此记录描述公开源码整理与软件复验；不新增真机验收结论。

## 来源与历史

- 原始完整源码包：`Waymate_Final_RC2_Source.zip`。解压后的 7,964 个文件逐文件 SHA-256 与 ZIP 一致。
- 整理前 GitHub `main`：`d46fe0d`。原始本地 `main`：`76ee61d902cc278d00cf2625973c8ff3ac3ec97f`，比远端多一个已提交的 Stage 8A 审计。
- 发布副本先克隆 GitHub 历史，再快进接入 `76ee61d`，随后同步 RC2 源码。未覆盖原始工作区；未提交的 ANCS 与 `design/` 文件原位保留，并另有本地补丁和文件备份，不进入公开仓库。
- RC2 对本地已提交基线有 38 个既有文件变化及 15 个新增非依赖文件，涉及 P0 动作处理、启动修复、Demo、圆屏 UI、测试和发布资料。
- RC2 包省略的 44 个旧硬件 CAD 构建目录文件仍保留在历史仓库中，避免丢失工程成果；这些文件不参与现用 Waveshare 固件构建。

## 产品源码与可复现依赖

`platforms/ios`、`platforms/esp32`、`shared` 和 `backend` 保存产品源码；`tests`、`scripts`、配置与锁文件保存复现工具。`hardware`、旧阶段文档和制造候选为历史工程参考，不代表现用硬件已制造或验收。

LVGL 沿用子模块提交 `85aa60d18b3d5e5588d7b247abf90198f07c8a63`（9.5.0）。源码包内已有文件与该提交逐文件一致；源码包省略的 121 个 LVGL 测试 `.bin` 由完整子模块克隆保留。ESP-IDF 托管组件由 `dependencies.lock` 和 `idf_component.yml` 获取，不提交 `managed_components` 缓存。

固件依赖锁移除作者机器绝对路径，保留相对路径；构建前通过 `scripts/rebind_lvgl_lock.py` 绑定当前工作区。发布构建的 2,024 项编译输入均来自发布副本、ESP-IDF SDK 或工具链，没有引用旧实验工作区。

## 公开整理中的改动

- 中英文 README 统一为 Waymate / Your Ride Companion，加入作者的研究生背景、骑行礼物动机、实际探索过程和 AI 辅助开发说明。
- 保留已有模拟器截图与 LVGL 软件渲染，并明确标注来源；实体照片和视频留待真实拍摄。
- iOS 项目移除本地签名 Team 值，安装者在 Xcode 选择自己的 Team。保留原 Bundle ID，避免既有安装用户误换身份导致数据不连续。
- 扩展 `.gitignore` 排除签名材料、个人凭据、设备备份与本地配置。
- 修复两项后端过时断言：`healthz` 现有响应中的 `real_navigation`、地图禁用模式与原因字段。没有修改网关产品行为。
- Cloudflare 开发工具更新为精确锁定的 Wrangler 4.149.0 / Miniflare 5.20261006.1-alpha，以修复审计报告中的间接依赖漏洞；复验结果见下方安全检查。
- 原有 LICENSE、NOTICE、第三方许可和 Required Notice 保留。RC2 原始交付记录中的安装与签名产物属于本地交付资料，不随公开源码上传。

## 软件复验

| 检查 | 结果 |
| --- | --- |
| Native CMake / CTest | 10/10 通过，包括实际 LVGL 软件渲染 |
| iOS App 单元测试 | 245/245 通过，iPhone 16 Pro / iOS 18.6 模拟器 |
| iOS Demo UI | 3/3 通过，包括完整 84 秒播放、控制与场景选择、退出恢复 |
| Swift Package | 19/19 通过 |
| Node 网关 | 61/61 通过，使用 mock 与 loopback，无真实导航密钥 |
| Cloudflare Workers | dry-run 构建与 7/7 本地运行时测试通过，无部署 |
| 离线地图 | fixture 生成一致；SQLite integrity=ok |
| ESP32 | ESP-IDF 5.5.5 完整构建通过，App 版本 0.3.2-final-rc2 |

本次重编译 App 为 1,441,424 字节。SHA-256：`5d9ebfafb364ed35a685bec0b4d249ccf99cec0c11ed04dc1bd79a1ac4a631ee`。该值记录本次构建，不承诺与原交付二进制字节一致；构建路径与构建元数据会影响镜像。编译产物仅保留本地。

## 安全与发布检查

待提交文件不包含 Apple 证书、私钥、Provisioning Profile、IPA、NVS/Bond 私人备份、本地账号凭据或编译缓存。历史 Gerber ZIP 仅包含制造输出，未引入设备备份。没有新增超过 20 MB 的文件。

Gitleaks 扫描待发布文件与本次新增历史，报告的两处通用 Key 命中均为 `AppModel.swift` 中的 `UserDefaults` 名称 `Waymate.RecentPlaces.v1` 和 `MotoGPS.RecentPlaces.v1`，不是 API 凭据。源码与归档内容另检查私钥标记及敏感文件类型。实际导航默认地址为 `example.invalid`，服务端配置保留示例值。

npm 审计：Node 网关 0 项漏洞；Cloudflare 开发依赖从 4 项高危报告修复为 0 项漏洞，更新后的 dry-run 与 7 项测试再次通过。

README 相对文件链接、图片引用、目录索引与 `git diff --check` 通过。发布采用普通 commit / push，保留既有历史，不使用强推或破坏性清理。

## 真机验证边界

本轮只构建和运行软件测试，没有安装到实体 iPhone、刷写圆屏、修改 NVS 或删除配对。历史 BLE、实体圆屏 Demo 和启动实验三次冷启动成功不计入 RC2 最新固件验收。

仍需按 [DEVICE_ACCEPTANCE.md](DEVICE_ACCEPTANCE.md) 完成 RC2 安装、冷启动、显示、运行时内存、BLE 重连、真实导航与道路推进，以及 Ride / Backtrack 道路测试。
