# 手动安装与回退

本发布包不会自动安装。保持原设备配对、App 数据和已有备份；不删除 App、不删除 Bond、不写 NVS。以下步骤仅在用户决定测试新候选时手动执行。

## iPhone

1. 解压 `Waymate_iOS_0.3.2_8_signed_App.zip` 得到 `Waymate.app`。核对 0.3.2 (8)，Bundle ID `com.zhengxiaohua.waymate.test2026`，签名未过期。
2. 连接已被开发 Profile 包含的 iPhone，启用其既有开发者模式。通过 Xcode → Window → Devices and Simulators → Installed Apps 的添加按钮选择该 App，进行同 Bundle ID 覆盖安装。不要先删除旧 App。
3. 首次打开核实真实 History、设置和 BLE 配对仍在；真实会话结束后才能进入 Demo。没有向 App 注入私有网关，正式路线需继续使用用户已有有效配置。
4. Profile 只覆盖当前配置的一个设备，到期时间北京时间 2026-10-19 17:03:18。其他设备或到期后，在交付源码中重新配置自己的签名并构建。

iOS 回退：使用此前稳定源码或已有旧构建，以相同 Bundle ID 和有效签名覆盖安装；继续保留 App 数据。发布包没有伪称备份当前 iPhone 可执行文件或数据；本轮未连接手机安装。不要通过卸载实现回退。

## ESP32 准备

同目录保留 `Waymate_Final_RC2.bin`、匹配 .elf/.map、两个手动脚本及旧 Startup Experiment 的 .bin/.elf。先核对 `SHA256SUMS.txt`。脚本针对当前已核实的 ESP32-S3 MAC `7c:0c:5f:42:3a:e4`，依赖本机 ESP-IDF 5.5.5 Python；换电脑或设备会拒绝或需重新核实路径／身份。

脚本默认 `check`；只有显式 `flash` 或 `restore` 允许写 App。历史私人 NVS / App 备份保持原位置：

`/Users/zhengxiaohua/Documents/Codex/2026-10-11/waymate-competition-rc-p0-2026-10/outputs/Historical_Backup`

这些私人备份没有装进源码或公共发布包。脚本会验证其完整性，同时要求安装前重新备份当前设备，历史成功不替代现场检查。

## 操作顺序

在发布目录中，按需逐步运行。`offline` 不打开串口；其余步骤需用户手动将设备置于下载模式并核实端口。不要照抄构建日志中的整套 flash 命令。

```sh
bash ESP32_Final_Manual_Install.sh offline
bash ESP32_Final_Manual_Install.sh check /dev/cu.usbmodem11401
```

`check` 读取芯片／安全状态、真实分区表、两份当前 NVS，比较逐字节与 SHA-256，并检查 NVS 完整性；备份完整当前 factory App（8 MiB）并 verify_flash。所有输出保存在新建的 `Final_RC_Installation_Backup/` 私人目录。当前 App 身份以这份现场备份为准，不能只根据开机图案认定版本。

全部 CHECK PASS 后，若用户决定安装，显式执行：

```sh
bash ESP32_Final_Manual_Install.sh flash /dev/cu.usbmodem11401
```

写入前再次核验设备身份、安全状态、分区表、NVS 和完整原 App。**仅写 factory App 的 `0x10000`，最大 8 MiB**；不写 bootloader、partition table、NVS、phy 或 storage。保留 Flash mode/freq/size，禁止 erase_flash、整片擦除、改 Bond 或恢复历史 NVS。

写入后自动校验 App、完整回读，确认 NVS 和分区表逐字节未变。仅全部 PASS 后，手动松开 BOOT 并复位／重上电正常启动。先做 [DEVICE_ACCEPTANCE.md](DEVICE_ACCEPTANCE.md) 的 T01，再 BLE、Demo。脚本操作后保持下载模式，不自动复位。

```sh
bash ESP32_Final_Manual_Install.sh verify /dev/cu.usbmodem11401
bash ESP32_Final_Monitor.sh candidate /dev/cu.usbmodem11401
```

monitor 使用匹配 .elf，采用 `--no-reset`。正常开机用 PWR，而不是按住 BOOT；串口监视不能替代独立冷启动测试。

## App-only 回退

若启动、显示、BLE 或 Demo 出现阻断，停止新功能验收。手动进入下载模式，执行：

```sh
bash ESP32_Final_Manual_Install.sh restore /dev/cu.usbmodem11401
```

恢复的是此次 `check` 留存的完整原 App，不覆盖回退时的当前 NVS；先双读并确认其稳定，再恢复 App，校验全量镜像和当前 NVS。即使新运行期间 NVS 已正常变化，也不会把它改成历史 NVS。会话恢复点不可覆盖；失败写入后仍可沿原会话回退。

`Rollback_Display_Startup_Experiment.bin/.elf` 是匹配的旧构建备用参考；它不能替代现场读取的当前 App。不要用历史 NVS 恢复 BLE 身份，也不要直接执行整包烧录。

本轮仅完成构建、产物校验和离线安装逻辑模拟；没有运行真实串口检查、刷写、verify 或 restore。
