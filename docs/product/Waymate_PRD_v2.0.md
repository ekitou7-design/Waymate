# Waymate PRD v2.0

## 1. 产品名称

**Waymate**

产品形态：摩托车智能第二屏 / 可定制骑行车机配件

首发硬件：Waveshare ESP32-S3-Touch-AMOLED-1.75C

首发平台：iPhone

---

# 2. 产品一句话定义

Waymate 是一块安装在传统摩托车上的智能第二屏。

iPhone 负责定位、导航、联网、媒体和数据处理，Waymate 圆屏负责骑行过程中最重要的信息显示和轻量操作。

它既是一块导航和骑行仪表，也是一件强调外观、自定义和 DIY 属性的摩托电子配件。

Waymate 的目标不是替代手机，而是像 Apple Watch 对 iPhone 一样，把手机中适合骑行的信息带到摩托车上。

---

# 3. 产品背景

大量传统摩托车只有基础机械或数字仪表，没有现代汽车和新能源车常见的车机系统。

骑手通常使用手机支架解决导航问题，但存在以下问题：

1. 手机长期固定在摩托车上承受震动，可能对设备造成损伤。
2. 手机并不是为摩托车骑行场景设计的车机界面。
3. 导航、音乐、骑行数据和通知分散在手机中。
4. 传统摩托车缺少现代化、可交互、可定制的数字体验。
5. 市面上已有摩托 CarPlay 类设备，但 Waymate 希望提供一个更小型、更 DIY、更可定制、更有仪表感的开源方案。

---

# 4. 产品核心价值

## 4.1 帅

Waymate 首先应该是一件让用户愿意安装在摩托车上的电子配件。

用户看到 Waymate 的第一反应应该是：

**“这是什么？好帅。”**

外观、启动动画、表盘、导航动效和整体车机感都属于核心产品价值，而不是后期装饰。

## 4.2 保护手机

减少用户将 iPhone 长时间固定在车把上的需求。

骑行开始以后，大部分查看行为在 Waymate 上完成。

## 4.3 少看手机

复杂操作仍由手机完成，但骑行过程中的高频信息由圆屏承担。

## 4.4 骑行记录

Waymate 不只是导航附件。

即使没有目的地，用户也可以开始一次 Ride，像使用跑步或骑行软件一样记录自己的行程。

## 4.5 自定义

Waymate 应具有：

- 自定义 Idle Face
- 用户上传壁纸
- 多套官方仪表模板
- 页面排序
- 页面开关
- 导航强调色
- 摩托参数配置

## 4.6 DIY / Open Source

V1 主要服务愿意自己购买硬件、刷固件、部署 App 和配置服务的用户。

Waymate 保持 Maker 项目属性。

---

# 5. 目标用户

## V1

单个骑手。

典型用户：

- 城市通勤
- 周末跑山
- 摩旅
- 已经使用手机导航和头盔蓝牙耳机
- 喜欢摩托电子配件和改装
- 愿意自己部署开源项目

V1 不要求用户注册 Waymate 账号。

## V2

两名及以上骑手。

逐步增加 Group Ride / 车队模式。

V2 车队功能第一优先级：

**掉队提醒。**

---

# 6. 产品原则

### 手机是大脑

iPhone 负责：

- GPS
- 网络
- 路线
- 导航计算
- 媒体
- Ride 数据
- 历史记录
- 复杂设置

ESP32 不建立第二套导航权威状态。

### 圆屏是骑行界面

圆屏负责：

- 快速查看
- 简单控制
- 导航提示
- 仪表
- 媒体
- 通知
- 本地动画
- 本地连接状态

### 复杂操作留给手机

包括：

- 搜索目的地
- 选择路线
- 页面排序
- 上传壁纸
- 设置摩托参数
- 查看完整 History
- 修改复杂配置

### 安全优先

骑行过程中不鼓励阅读长文本和进行复杂操作。

如果“交互丰富”和“安全”发生冲突：

**安全优先。**

---

# 7. V1 产品范围

V1 的三个核心能力：

**Navigation**

**Ride Dashboard**

**Ride Tracking**

同时 V1 必须具备两个辅助能力：

**Media**

**Notifications**

因此 V1 不是五个同等级核心模块。

产品核心仍然是：

导航 + 仪表 + 骑行记录。

媒体和通知属于第二屏应具备的基础便利功能。

---

# 8. 产品状态模型

Waymate 的主要状态为：

```text
Power On
   ↓
Idle
   ↓
Ride Session
   ↓
Ride Summary
   ↓
History
```

Navigation 属于 Ride Session 中可以开启的一种能力。

---

# 9. Idle Mode

设备通电后：

```text
Waymate Boot Animation
        ↓
Idle Face
```

Idle Face 包含：

- 用户上传的一张背景图片
- 时间
- 手机连接状态
- 设备电量
- 必要系统状态

V1 只保存一张用户壁纸。

用户在 iPhone App 中选择照片，并进行圆形裁切预览。

圆屏显示结果应尽可能与手机预览一致。

V1 使用固定模板，不提供自由拖拽布局。

未来可增加多个自由表盘。

### 未连接手机

仍然允许显示：

- 壁纸
- 时间
- 未连接状态

### 屏幕策略

Idle 状态不 Always-On。

Active Ride / Navigation 状态保持亮屏。

骑行停止一段时间后允许熄屏。

通过：

- 触摸
- 实体按钮

重新唤醒。

亮度 V1 采用手动调节。

---

# 10. Ride Session

用户可以从：

- iPhone
- 圆屏

开始一次 Ride。

点击：

**Start Ride**

后开始记录：

- GPS 轨迹
- 总时间
- Moving Time
- 距离
- 当前速度
- 平均速度
- 最高速度

### Pause Ride

暂停时：

- 不累计 Moving Time
- 不继续累计移动距离
- Ride Session 本身不结束

Navigation 可以继续工作。

### 自动结束提醒

连续静止约 20 分钟后：

提示用户：

**“骑行似乎已经结束，是否结束 Ride？”**

不直接强制结束。

### 时间统计

Ride Summary 同时保留：

- Elapsed Time
- Moving Time

中途停车吃饭不应被误算为骑行运动时间。

---

# 11. Navigation 与 Ride 的关系

如果用户：

**Start Navigation**

Waymate 自动：

```text
Create Ride Session
       +
Start Ride Tracking
       +
Start Navigation
```

用户不需要再额外点击一次 Start Ride。

V1 默认所有 Navigation 都记录一次 Ride。

如果用户不希望保留，可以在 Ride History 中删除该记录。

### End Navigation

不等于 End Ride。

用户抵达导航目的地后仍然可能继续骑行。

---

# 12. Navigation

Navigation 是 Waymate 的最高优先级核心功能。

目的地搜索只在 iPhone 完成。

圆屏不提供键盘搜索。

用户：

```text
iPhone 搜索目的地
→ 选择路线
→ Start
→ 圆屏自动进入 Navigation
```

### 必须显示

- 转向箭头
- 距离下一操作
- 剩余总距离
- 剩余时间
- ETA
- 车道提示

### 最好支持

- 下一道路名称
- 当前速度
- 限速
- 超速提醒
- 路口放大
- 红绿灯
- 环岛出口
- 局部地图
- 整体路线预览

当屏幕空间发生冲突：

**转向箭头 / 距离 / 车道提示优先于地图。**

---

# 13. Navigation 强提醒

Waymate 参考 Apple Watch 的导航提醒思路，但由于圆屏缺少腕部触觉体验，使用视觉提醒作为主要补偿。

普通状态：

深色主题正常显示。

接近重要转向：

界面短暂使用高对比强调。

即将转向：

进一步强化箭头、距离或背景。

用户可以选择自己的 Navigation 强调色。

不使用持续快速闪烁。

未来硬件支持时可以加入：

- 震动
- 蜂鸣器
- 音频提示

---

# 14. Navigation 网络异常

网络断开时：

- 明确提示 Network Unavailable
- 已经存在的当前路线可以继续显示
- 不假装拥有新的在线路线能力
- 无网络时不能正常重新规划，则明确告知用户

GPS 与网络状态必须区分。

---

# 15. Home / 页面模型

圆屏页面由用户在 iPhone App 中配置。

例如：

```text
≡ Navigation
≡ Ride
≡ Music
≡ Notifications
```

用户可以：

- 排序
- 开启
- 关闭

左右滑按照用户设置顺序切换。

### Home

普通 Ride：

Ride Dashboard 是 Home。

正在 Navigation：

Navigation 是 Home。

实体快捷键第一功能：

**返回当前 Home。**

---

# 16. Primary Page 与 Notification Layer

Waymate 不采用“任何事件都强制抢整个页面”的设计。

显示系统分成：

```text
Primary Page
+
Notification Layer
```

例如用户正在 Navigation：

Navigation 继续正常显示。

收到微信：

只显示通知图标 + 未读红点。

不会直接用微信内容覆盖导航。

Notification Layer 可以用于：

- 手机通知
- Waymate 系统提醒
- 网络状态
- 后续车队提醒
- 后续 Camera 状态

---

# 17. Ride Dashboard

Dashboard 第一视觉中心：

**速度。**

速度位于屏幕中央并保持最大视觉权重。

圆形外围可以展示：

- 模拟 RPM
- 模拟 Gear
- Ride Time
- 其他骑行指标

V1 提供多套官方模板，例如：

- Classic
- Sport
- Touring
- Minimal

用户选择模板，而不是自由拖拽创建布局。

---

# 18. 模拟 RPM / Gear

RPM / Gear 属于视觉和娱乐功能。

它们不是 ECU / CAN 真实数据。

用户可以关闭。

首次开启时必须明确说明：

**RPM / Gear 为估算值。**

以后无需在主界面持续显示免责声明。

V1 用户配置：

- 排量
- 档位数
- 红线转速

系统据此生成更合理的模拟结果。

无需维护全球摩托车型数据库。

---

# 19. 超速提示

如果当前速度超过已知限速：

速度可以：

- 变为红色
- 或使用用户选择的强调色

限速数据不可用时不得自行猜测。

---

# 20. Ride Summary

End Ride 后自动生成：

```text
WAYMATE RIDE

Distance
Elapsed Time
Moving Time
Average Speed
Max Speed

Route Map
```

用户可以为 Ride 自定义名称。

例如：

**第一次太湖**

Ride 保存在 History 中，直到用户主动删除。

V1 数据全部保存在 iPhone 本地。

卸载 App 导致本地数据丢失，V1 可接受。

未来考虑 iCloud。

---

# 21. Ride Share Card

用户可以从 Summary 生成分享卡片。

至少包含：

- Waymate 品牌
- Ride 名称
- 地图路线
- 距离
- 时间
- 速度数据

这是 Waymate 仪式感和视觉表达的重要部分。

---

# 22. GPX

V1 可以支持导出 GPX。

GPX 属于较高价值的 DIY / 摩旅能力，但优先级低于核心 Ride 闭环。

---

# 23. Media

V1 必须包含 Media。

产品目标：

尽可能显示 iPhone 当前正在播放的媒体，而不是只针对某一个音乐 App。

首版实际支持范围以 iOS 系统能力为准。

Media 页面目标：

- 歌名
- 歌手
- 播放状态
- 播放进度
- 上一首
- Play / Pause
- 下一首
- 专辑封面（条件允许）

优先级：

控制能力
>
文字信息
>
播放进度
>
专辑封面

不在圆屏提供音量控制。

---

# 24. Notifications

Notifications 属于 V1。

用户在 iPhone App 中选择希望同步通知的 App。

骑行过程中优先显示：

- App / 消息来源
- 发送人
- 一行以内简要提示

避免展示长消息。

未读通知通过：

**通知图标 + 红点**

表达。

### Notification Center

点击通知图标后可以查看当前 Ride 中尚未查看的通知。

已查看消息从未读列表清除。

### Quick Reply

目标提供约 5 个用户自定义快捷回复。

例如：

- 正在骑车，晚点回复
- 快到了
- 收到
- 等我一下
- 好

理想交互：

点击即发送。

如果 iOS 或第三方 App 不允许 Waymate 代替用户发送：

V1 自动降级为只读通知，不伪造能力。

---

# 25. Media / Notifications 的安全限制

骑行期间：

- 不展示超长文本
- 不允许复杂设置
- 页面排序、壁纸设置、摩托参数设置等留在手机端
- 圆屏只承担快速查看和轻量操作

---

# 26. Backtrack

Ride Tracking 与 Backtrack 是两个功能。

Ride Tracking：

记录“我骑过哪里”。

Backtrack：

使用已经记录的轨迹指导用户原路返回。

典型场景：

用户跑山进入陌生道路，希望沿刚才经过的路线返回。

Backtrack 不作为 V1 首发核心要求。

计划进入：

**V1.x**

第一版目标：

从当前位置沿当前 Ride 已记录轨迹反向回到起点。

以后再支持：

返回历史轨迹中的任意点。

---

# 27. Camera

Camera 不属于 V1 核心。

第一目标设备：

**Insta360 Ace Pro 2**

首个可用版本只需要：

- 显示连接状态
- 显示 REC 状态
- 开始录像
- 停止录像

不要求首版支持多个品牌。

---

# 28. Group Ride

Group Ride 属于 V2。

V1 不包含：

- 账号系统
- 好友
- 实时队友位置
- 车队聊天室
- 云端 Ride 同步

V2 第一项车队能力：

**掉队提醒。**

后续再增加：

- 队友位置
- 在线状态
- 一键消息
- 集合点
- 共同目的地

---

# 29. 平台路线

## V1

iPhone + 1.75C

单骑手

## V1.x

Backtrack 等增强能力

## 后续

Android

## V2

Group Ride / 多骑手模式

---

# 30. 硬件边界

V1 锁定当前：

**Waveshare ESP32-S3-Touch-AMOLED-1.75C**

不因为产品设计阶段再更换正式硬件。

当前供电：

以现有内置电池方案为基础。

V1 当前不解决：

- 正式车辆取电
- 商业级防水
- 大规模硬件量产问题

实体按键继续保留。

骑行中的第一快捷键：

**Home。**

---

# 31. 软件架构方向

Waymate 使用：

```text
iPhone
  │
Waymate State / Services
  │
Component States
  │
PresentationCoordinator
  │
Primary Page + Notification Layer
  │
Display Adapter
  │
BLE
  │
ESP32
  │
Renderer
```

计划中的语义组件包括：

- Navigation
- Ride
- Media
- Notifications
- Track
- Future Group Ride
- Future Camera

Component 负责：

**“现在有什么状态？”**

PresentationCoordinator 负责：

**“现在应该展示什么？”**

Renderer 负责：

**“具体怎么画？”**

---

# 32. 架构原则

保留当前已经稳定工作的：

- C++ NavCore
- Navigation Runtime
- NavPresenter
- shared/nav_ui
- BLE v1

不得为了“架构漂亮”重新实现这些成熟模块。

Component Architecture 应渐进迁移。

---

# 33. V1 完成定义

Waymate V1 完成，不以“代码写完”为标准。

而以一个真实骑手是否能够完成下面整个流程为标准：

用户自行准备指定 1.75C 硬件并部署 Waymate。

配对自己的 iPhone。

设置自己的 Idle Face。

设备安装到摩托车。

开始一次真实 Ride。

圆屏正常显示漂亮且可用的 Dashboard。

Ride 真实记录 GPS 轨迹。

用户可以在手机选择一个目的地并开始真实 Navigation。

圆屏能够在真实骑行过程中稳定提供导航信息。

Media 可以进行基础显示和控制。

重要手机通知可以安全地出现在圆屏。

Ride 结束后生成真实 Summary。

历史 Ride 可以再次查看并导出/分享。

整个流程中用户无需把手机固定在车把上。

设备经历：

- 户外骑行
- 手机锁屏
- BLE 短暂断连
- 网络变化
- 停车
- 恢复骑行

仍然能够稳定工作。

只有达到这一标准，Waymate V1 才算真正完成。

---

# 34. 产品最终评价标准

Waymate 不追求：

“功能比手机更多。”

Waymate 应该做到：

**把手机已有的能力，变成真正属于摩托车的数字体验。**

产品成功时，用户看到装在摩托车上的 Waymate，第一反应应该是：

**“这是什么？好帅。”**

然后真正骑出去以后发现：

**“而且它真的有用。”**
