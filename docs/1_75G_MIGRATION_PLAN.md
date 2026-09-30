# 1.75C → 1.75-G 最小迁移分析

**目标板：** Waveshare ESP32-S3-Touch-AMOLED-1.75-G，SKU 31264

**当前状态：** 只做迁移准备和风险核对；不修改代码，不写 LC76G 驱动，不修改 BLE、iOS 或 Backtrack。

**当前仓库基线：** ESP32 固件仍按 1.75C 编写，主要入口为 `platforms/esp32/main/app_main.cpp`，板级实现为 `platforms/esp32/main/board_port_waveshare_1_75c.cpp`。

官方资料：

- [1.75-G 官方产品页](https://docs.waveshare.com/ESP32-S3-Touch-AMOLED-1.75)
- [1.75C 官方产品页](https://docs.waveshare.com/ESP32-S3-Touch-AMOLED-1.75C)
- [Waveshare 1.75 官方工程仓库](https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-1.75)
- [官方硬件参考 HARDWARE_REFERENCE.md](https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-1.75/blob/main/HARDWARE_REFERENCE.md)

## 1. 1.75C 和 1.75-G 的关键硬件差异

| 项目 | 当前 1.75C 基线 | 1.75-G / SKU 31264 | 对 Waymate 的影响 |
|---|---|---|---|
| 主控 | ESP32-S3R8 | ESP32-S3R8 | 主控架构可继续使用 |
| PSRAM | 8MB | 8MB | 现有 PSRAM 缓冲策略可以作为候选方案，但仍需实机验证 |
| 外部 Flash | 32MB | 16MB | 当前 `sdkconfig.defaults` 的 32MB 配置不能直接沿用；分区、镜像和存储余量必须重新核对 |
| 显示 | 1.75 英寸、466×466、CO5300、QSPI | 1.75 英寸、466×466、CO5300、QSPI | 显示协议和分辨率方向相同，现有显示路径有较高复用可能 |
| 触摸 | CST9217，I2C | CST9217，I2C | 现有触摸组件和 UI 接口有较高复用可能 |
| IMU | QMI8658 | QMI8658 | 现有 QMI8658 方向辅助逻辑可作为复用候选，但轴向、中断和设备 ID 必须实测 |
| 电源 | AXP2101 | AXP2101 | PMIC 地址和主要功能可复用候选；电源键检测路径不能直接假定相同 |
| I/O 扩展 | 当前仓库未直接使用 TCA9554 管理电源键 | 官方 G 参考使用 TCA9554，地址 `0x20` | G 版 PWR、GNSS 复位和部分中断路径需要纳入板级核验 |
| 电源键 | 当前代码按 GPIO3 / SYS_OUT 读取 | 官方 G 参考为 TCA9554 P4 / EXIO4 读取 SYS_OUT | 当前 `GPIO3` 假设是迁移高风险点 |
| GNSS | 当前仓库无板载 GNSS 路径 | LC76G，需外接 GPS 陶瓷天线 | 需要单独验证，不在本次迁移中写驱动 |
| GNSS 复位 | 无现有代码 | 官方 G 参考为 TCA9554 P7 / EXIO7 | 未来 GNSS 板级适配必须使用实机确认后的路径 |
| GNSS UART | 无现有代码 | 官方 G 参考可能使用 GPIO17/18 | 需要确认实际板卡跳线/路由，不能把扩展 GPIO 当作必然 UART |
| 共享 I2C | 当前代码通过 `bsp_i2c_get_handle()` 使用 | G 版官方参考为 GPIO14/15，共享多个器件 | LC76G 必须复用同一 I2C 总线并核对地址和速率 |

官方 G 参考列出的 I2C 地址包括：TCA9554 `0x20`、AXP2101 `0x34`、CST9217 `0x5A`、QMI8658 `0x6B`，以及 LC76G 使用的 `0x50` / `0x54`。参考资料同时提醒，官方 BSP 默认 400kHz，而独立 LC76G 示例使用 100kHz；最终速率必须由所有实际启用器件共同决定。

## 2. 哪些现有代码可以直接复用

这里的“直接复用”表示代码结构和职责可以保留，不表示不经过 G 版 BSP 编译和实机验证即可刷写。

### 可以优先复用

- `platforms/esp32/main/app_main.cpp` 的启动顺序、LVGL 锁、BLE 启动和 QMI 启动流程；
- `platforms/esp32/main/board_port.h` 的板级接口契约，前提是把电源键/睡眠细节继续封装在 board port 内；
- `motion_heading_sensor.cpp` 的 QMI8658 采样、重力投影和相对转向辅助逻辑；
- CO5300 的 `esp_lcd` 公共接口、466×466 RGB565 约束、PSRAM 双缓冲和 TE 同步思路；
- CST9217 的 LVGL 注册方式和现有触摸坐标变换配置，待实机确认方向；
- AXP2101 的 I2C 地址和读改写寄存器处理方式，待实机确认电源路径；
- 共享 UI、导航快照、BLE transport 和 iPhone 当前导航链路。

### 不能作为“直接复用”的部分

- 整个 `board_port_waveshare_1_75c.cpp` 不能未经核验直接当作 G 版 board port；
- GPIO3 电源键读取和 `1ULL << 3` 深度睡眠唤醒不能直接沿用；
- 当前 `waveshare/esp32_s3_touch_amoled_1_75c` 组件依赖不能直接代表 G 版 BSP；
- 当前 AXP2101 电源键时序不能在 G 版上未经实测直接放行；
- 当前仓库没有可复用的 LC76G 驱动、GNSS 任务或 GNSS 协议实现。

## 3. 哪些文件未来必须修改

以下是拿到 G 板并完成官方示例验证后，最小迁移可能涉及的文件。当前不修改。

| 文件 | 未来修改原因 | 最小修改方向 |
|---|---|---|
| `platforms/esp32/sdkconfig.defaults` | 当前明确写入 1.75C / 32MB Flash | 改为 G 版实际 Flash 配置；保留 8MB PSRAM、BLE 和现有运行时参数，除非实机证明需要变化 |
| `platforms/esp32/partitions.csv` | 当前工件包含 8MB factory + 7MB storage，且没有针对 G 版验证 | 先确认总容量、镜像大小和存储需求；16MB 能否保留现布局必须由实际构建产物确认，不预设扩大分区 |
| `platforms/esp32/main/idf_component.yml` | 当前依赖 `waveshare/esp32_s3_touch_amoled_1_75c` | 改为官方 G/通用 1.75 BSP 对应组件，并核对组件版本和 API |
| `platforms/esp32/dependencies.lock` | 锁定了 C 版 BSP 及其间接依赖 | 在 manifest 确认后重新生成并审核锁文件，不手工拼接组件版本 |
| `platforms/esp32/main/CMakeLists.txt` | `REQUIRES` 当前写入 `esp32_s3_touch_amoled_1_75c` | 切换到 G 版 BSP 组件名称；只有在实际 GNSS 方案确定后才增加额外依赖 |
| `platforms/esp32/main/board_port_waveshare_1_75c.cpp` 或新的 G 版 board port | 当前包含 C 版 GPIO、电源、BSP 和 CO5300 初始化假设 | 保留 C 兼容路径，新增或分离 G 版板级实现；不要直接覆盖 C 版本 |
| `platforms/esp32/main/board_port.h` | G 版电源键、睡眠唤醒和未来 GNSS 复位可能需要更清晰的板级接口 | 只有当前接口无法封装 G 版差异时才扩展 |
| `platforms/esp32/main/app_main.cpp` | 当前深睡眠唤醒直接使用 GPIO3 | 应改为调用板级唤醒配置接口，或使用经过 G 实测的唤醒来源 |
| `platforms/esp32/README.md` | 当前文档明确写着“只适用于 1.75C”和 32MB Flash | G 版验证通过后再补充型号和刷写边界 |

LC76G 未来需要新增独立的板级适配/数据接入代码，但不属于本次迁移准备的实现内容，也不应在本阶段修改 BLE。

## 4. 哪些地方必须拿到实机后才能确认

### Flash、启动和存储

- 实际 Flash 容量是否为 16MB；
- Flash mode、频率和 PSRAM 初始化是否与官方 G 示例一致；
- 原厂应用、Flash 加密和安全启动状态；
- 现有 `partitions.csv` 在 16MB 下是否满足镜像和存储需求；
- 迁移后的 Waymate 镜像是否超出 8MB factory 分区。

### 显示和触摸

- CO5300 实际初始化命令、亮度和显示方向；
- TE GPIO13 的波形、频率和极性；
- 466×466 RGB565 是否稳定；
- CST9217 触摸坐标是否仍需当前的 `mirror_x/mirror_y`；
- 显示复位 GPIO39 和触摸复位 GPIO40 是否与 G 官方参考一致。

### IMU 和 I2C

- QMI8658 设备 ID、I2C 地址和 INT1/INT2 路径；
- 当前轴向映射是否适用于 G 板实物安装方向；
- QMI8658 和 AXP2101 是否可继续共享当前 BSP I2C handle；
- 加入 LC76G 后总线速率、访问时序和地址是否稳定。

### AXP2101、TCA9554、电源键和睡眠

- AXP2101 `0x34` 是否可读写；
- 电池供电、USB 供电和无电池 USB 供电三种情况下的开关机行为；
- PWR 键是否确实由 TCA9554 P4 / EXIO4 提供 SYS_OUT；
- TCA9554 地址 `0x20` 和 P7 / EXIO7 的输出行为；
- QMI INT1、AXP IRQ、GPS_RST 是否占用 TCA9554 其他引脚；
- 长按关机、软件关机、USB 供电深睡眠和下一次按键唤醒；
- GPIO3 是否已经是 G 版 TF 卡 SD_D0，不能再作为电源键或唤醒 GPIO 使用。

### LC76G

- 板上是否确实安装 LC76G，以及外接 GPS 陶瓷天线是否正确连接；
- I2C `0x50` / `0x54` 的实际读写行为；
- GPIO17/18 是否实际连到 LC76G UART；
- GPS_RST 是否由 TCA9554 P7 控制；
- 是否存在可用 PPS 信号及其实际引脚；
- 冷启动、热启动、室内无 Fix、户外 Fix 时间和持续定位稳定性；
- GNSS 工作时是否影响显示、触摸、IMU、BLE 或电源管理。

## 5. 板子到手后的验证顺序

1. **不刷 Waymate，先确认板卡身份。** 读取 Flash ID、安全启动/加密状态，保存原厂全片备份和校验值。
2. **运行官方 HelloWorld / 显示示例。** 确认 CO5300、QSPI、分辨率、颜色、亮度和基本刷新。
3. **运行官方 CST9217 触摸示例。** 确认触摸中断、复位、坐标方向和多点/单点行为。
4. **运行官方 QMI8658 示例。** 确认加速度、陀螺仪、地址、轴向和中断状态。
5. **运行官方 AXP2101 示例。** 确认电池/电源遥测、充放电状态和 PMIC I2C 通信。
6. **单独验证 TCA9554。** 确认地址 `0x20`、P4 电源键状态、P7 GPS_RST 输出以及其他被占用引脚；没有确认前不启用 Waymate 的 GPIO3 电源逻辑。
7. **运行官方 LC76G I2C 示例。** 外接正确天线，在户外确认 I2C 读写、复位和定位输出；暂不接入 Waymate。
8. **验证 USB、TF/存储和睡眠边界。** 重点确认 GPIO3、USB、分区和电源状态之间没有冲突；TF 示例只作为存储后续路线的参考。
9. **最后才构建 Waymate 的 G 版最小端口。** 第一目标只包括显示、触摸、IMU、PMIC、BLE 和现有 iPhone 导航显示，不加入 GNSS 功能。
10. **G 版 Waymate 基线稳定后，再单独规划 LC76G 接入。** 这一步不属于本次迁移准备。

## 6. 官方示例中应该优先运行哪些示例

Waveshare 官方 1.75 工程仓库列出的示例中，优先级如下：

### 必跑

1. `01_HelloWorld`：确认 CO5300 显示、QSPI 和基本屏幕初始化；
2. `10_Touch_CST9217`：确认触摸控制器、中断、复位和坐标；
3. `04_LVGL_QMI8658_ui`：确认 QMI8658 和 LVGL 集成；
4. `05_LVGL_AXP2101_ADC_Data`：确认 AXP2101、电池和电源遥测；
5. `09_LC76G_I2C`：确认 G 版 LC76G 的 I2C 路径、地址和基本定位输出。

### 用于综合回归

- `06_LVGL_Widgets`：综合观察 LVGL、触摸、IMU 和页面交互，可放在单项验证之后运行；
- `07_LVGL_SD_Test`：如果后续轨迹记录准备使用 TF 卡，再运行；它不是 1.75-G 显示/导航迁移的第一阻塞项。

### 当前不必优先

- `03_LVGL_PCF85063_simpleTime`：RTC 不属于本次最小迁移阻塞项；
- `08_ES8311`：音频不属于本次检查范围；
- 其他与音频或完整示例应用有关的工程。

`09_LC76G_I2C` 是官方 Arduino 示例。它应先作为 G 版电气、I2C 地址和模块行为的参考验证，不应直接复制进当前 ESP-IDF 固件。

## 7. 从“原厂示例正常”到“Waymate 固件正常”的最短路径

```text
原厂备份与 Flash/安全状态确认
        ↓
官方 G 版 HelloWorld 正常
        ↓
官方触摸、QMI8658、AXP2101、TCA9554 单项正常
        ↓
官方 LC76G I2C 示例在户外正常
        ↓
建立独立的 G 版 ESP-IDF 配置和组件锁定
        ↓
仅迁移显示、触摸、IMU、PMIC、BLE 和现有 iPhone 导航显示
        ↓
验证 Waymate G 版不接 GNSS 时的原有功能
        ↓
再单独设计 LC76G 接入，不改动现有 BLE/iOS 基线
```

最小策略是：先让 G 版运行现有 Waymate 的“屏幕 + 触摸 + IMU + 电源 + BLE + iPhone 导航显示”，并把 GNSS 保持为后续独立任务。这样可以把“板级迁移失败”和“GNSS 接入失败”分开定位，也能保留 1.75C 的兼容实现。

本阶段的放行条件不是“理论上组件名称相同”，而是：G 版硬件实测通过、16MB 镜像和分区通过、PWR/睡眠路径通过、现有 iPhone BLE 导航显示通过。GNSS 驱动、BLE 扩展、iOS 修改和 Backtrack 均不属于本计划。
