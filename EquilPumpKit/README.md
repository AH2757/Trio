# EquilPumpKit

微泰 Equil 贴敷式胰岛素泵的 Trio / LoopKit 泵驱动层（Swift）。

`EquilKit` 负责"协议怎么说"，`EquilPumpKit` 负责"把协议接到 LoopKit 的泵抽象接口上"：
把 AAPS 的 `EquilManager`（业务编排）+ `EquilPump`（LoopKit 对接）两层逻辑搬成 Swift。

## 分层

```
LoopKit (PumpManager / PumpManagerDelegate / DoseEntry / Alert)
        ▲
        │ 实现抽象接口
EquilPumpKit
  ├── EquilPumpManager           核心：协议属性、BLE 栈装配、状态通知、事件发射
  ├── EquilPumpManager+Sync      ensureCurrentPumpData / 广播遥测 / 历史游标追赶
  ├── EquilPumpManager+Commands  大剂量 / TBR / 暂停恢复 / 基础率表 / 限值
  ├── EquilPumpState             可持久化状态（对接 RawStateValue）
  ├── EquilPumpState+Settings    把状态暴露成 EquilKit 命令层的设置存储
  ├── EquilCommandExecutor       用完即走 + 单槽串行 + 重试自愈
  ├── EquilAlert                 告警（对接 Alert / AlertResponder）
  └── 剂量模型与工具              UnfinalizedDose / NewPumpEvent / 进度估算 / 广播解码
        ▼
EquilKit (协议层：命令、AES、链路状态机、Core Bluetooth 传输)
```

界面层 `EquilPumpKitUI`（`PumpManagerUI` 的 onboarding / 设置 / HUD 与 `EquilPumpKitPlugin` 插件入口）
建立在上述驱动层之上，详见 [泵驱动层实现说明](../docs/10-泵驱动层实现说明.md)。

三层结构（对照 MedtrumKit 的 `MedtrumPumpState` → `StateSyncer` → `MedtrumPumpManager`）：

1. **状态模型**（`EquilPumpState`）：可持久化，直接实现 `RawRepresentable` 对接
   `PumpManager.RawStateValue`；连接期瞬态（是否已绑定、是否已连接）不持久化——
   对照 AAPS，App 重启一律视为未绑定，这是"用完即走"架构的前提。
2. **命令执行器**（`EquilCommandExecutor`）：把 AAPS `EquilManager` 的命令调度逻辑搬过来，
   统一处理绑定、节流、重试与自动解绑。
3. **驱动主类**（`EquilPumpManager`）：把上面两层粘到 LoopKit 抽象接口上，
   按职责拆到 `+Sync` / `+Commands` 两个扩展文件。

## 硬约束（来自 `docs/08-AAPS可借鉴逻辑清单.md`）

1. **用完即走**：业务命令前自动 `CmdPair` 绑定，空闲 5 秒（闭环活跃期 60 秒）自动
   `CmdUnPair` 并主动断连，官方控制器可随时接管。
2. **不写 CCC**：全部 AES 命令 `preferNoCccSubscription = true`，跳过 f001 的 2902 描述符。
3. **不 createBond**：直接 GATT 连接，不做系统配对。
4. **绑定与输注独立**：解绑后泵继续按本地基础率输注，解绑不等于暂停。
5. **剂量前置条件**：下发前泵必须处于 `RunMode.run`；暂停/停止态一律拒绝。
6. **大剂量与 TBR 互斥**：泵不支持同时输注。
7. **TBR 覆盖前先取消**：固件拒绝在已有 TBR 上覆盖，`enactTempBasal` 以 `step=0` 表达取消。

## 命令执行模型

- **单槽串行**：一次只执行一条命令（对照 AAPS 的 `cmdLock`），全部在专用串行队列上运行。
- **背靠背节流**：命令间最小间隔 500ms；定位循环 / TBR / 状态查询走 200ms 白名单。
- **重试自愈**：默认重试 2 次；AES 命令 `connectError`（能连但会话静默）→ 下轮强制重绑；
  `notFound`（auto-unpair 让位）→ 立即结束交给队列复用连接。
- **等待预算**：`命令超时 + （链路未就绪时）连接超时 + 2s 余量`。
- **绝不阻塞主线程**：`BaseCmd.waitForCompletion` 会阻塞线程，命令必须在命令队列上执行。

## 剂量换算（对照 AAPS 实测）

| 项 | 步进 | 范围 | 编码 |
| --- | --- | --- | --- |
| 基础率 | 0.01 U/h | 0.05–3.0（默认 maxBasal 20） | `basalToByteArray(rate / 2)` |
| 大剂量 | 0.05 U | —（默认 maxBolus 10） | `step = round(insulin / 0.05 * 8)` |
| TBR | 0.05 U/h | — | `step = (insulin / 0.05 * 8) / 2` |
| TBR 反解 | — | — | `rate = step * 0.0125` |
| 储药器 | — | 200 U | — |

大剂量输注速率由 `state.bolusRate`（枚举 ×10）决定：15 → 1.5 U/min（默认），30 → 3.0 U/min。

## 遥测与同步

- **广播**（28 字节，无需绑定）：电量 [17]、药量 [18]、基础率 [19–20]、历史游标 [23–24]、
  事件 [25–27]。AAPS v39 起停用主动轮询，电量/药量主要来自广播。
- **主动同步**（`ensureCurrentPumpData`）：数据新鲜窗口 4.5 分钟，超时才跑一轮
  `运行模式 → 药量 → 当前 TBR → 历史追赶`。
- **历史追赶**：从 `startHistoryIndex` 追到广播给出的 `historyIndex`，每次上限 20 条；
  首次对齐直接跳到最近一条，避免回放整段历史。已知告警码 `(4,8,0)` 推杆回退、`(5,1,0)` 异常断电。

## 结构

```
EquilPumpKit/
├── Package.swift                        模块骨架（本地依赖 EquilKit + LoopKit）
├── EquilPumpKit/                        驱动层（PumpManager）
│   ├── EquilPumpManager.swift           核心：协议属性 / 初始化 / BLE 装配 / 状态通知
│   ├── EquilPumpManager+Sync.swift      ensureCurrentPumpData / 广播解码 / 历史追赶
│   ├── EquilPumpManager+Commands.swift  剂量命令全量接口
│   ├── EquilPumpManager+Onboarding.swift 向导命令（配对校验 / 更换储药器）
│   ├── EquilPumpState.swift             可持久化状态 + EquilAlarm
│   ├── EquilPumpState+Settings.swift    设置存储桥接
│   ├── EquilCommandExecutor.swift       命令执行器（用完即走 / 串行 / 重试）
│   ├── EquilAlert.swift                 告警映射
│   ├── EquilAdvertisement.swift         广播解码
│   ├── EquilBolusProgressReporter.swift 大剂量进度估算
│   ├── UnfinalizedDose.swift            未定稿剂量模型
│   ├── NewPumpEvent+Equil.swift         LoopKit 泵事件构造
│   ├── EquilPumpError.swift             驱动层错误
│   └── Support/EquilUnits.swift         时间/数值换算
└── EquilPumpKitUI/                      界面层（PumpManagerUI）
    ├── EquilPumpManager+UI.swift        PumpManagerUI 一致性（向导 / 设置 / HUD）
    ├── EquilKitUICoordinator.swift      向导 / 设置流程协调器
    ├── EquilHUDProvider.swift           HUD Provider
    ├── Plugin/EquilPumpKitPlugin.swift  插件入口
    ├── ViewModels/                      各屏视图模型
    └── Views/                           各屏 SwiftUI 视图 + 通用组件
```

## 构建与验证

```sh
# 需要 Mac（Xcode）或 macOS 的 Swift 工具链；Core Bluetooth 仅在 Apple 平台可用
cd EquilPumpKit && swift build
```

`Package.swift` 用本地路径依赖 `../EquilKit` 与 `../LoopKit`，
便于在 Mac 上单独 `swift build` 验证本驱动层；`swift build` 会一并构建 `EquilPumpKit` 与
`EquilPumpKitUI` 两个目标。真正接入 Trio 时按 MedtrumKit 的方式加入 `Trio.xcodeproj` 子工程即可。

## 尚未完成

- **真机编译与联调**：当前开发机为 Windows，无法本地编译。工程已接入 `Trio.xcworkspace`
  （新增 `EquilPumpKit.xcodeproj` 引用）与 `Trio.xcodeproj`（`EquilKit` / `EquilPumpKit` /
  `EquilPumpKitUI` 三个 framework 的文件引用、链接阶段与嵌入阶段条目已按 MedtrumKit 方式补齐），
  待用 GitHub Actions 云端构建跑通。
- **CCC 画像真机验证**：iOS 只能用 `setNotifyValue` 订阅（必然写 2902），与 AAPS
  "跳过 CCC 才进控制端口"的结论冲突，见 [iOS BLE 移植说明](../docs/09-iOS%20BLE%20移植说明.md)。
- **报警字段语义标定**：广播/历史事件码目前只识别推杆回退、异常断电与默认堵管分类，
  其余字段待真机标定。

## 相关文档

- [泵驱动层实现说明](../docs/10-泵驱动层实现说明.md)
- [AAPS 可借鉴逻辑清单](../docs/08-AAPS可借鉴逻辑清单.md)
- [iOS BLE 移植说明](../docs/09-iOS%20BLE%20移植说明.md)
- [微泰设备接入方案](../docs/07-微泰设备接入方案.md)