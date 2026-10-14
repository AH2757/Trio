# EquilKit

微泰 Equil 贴敷式胰岛素泵的 iOS 协议层（Swift）。从 AndroidAPS 的 Kotlin 实现移植，
只做协议与命令，不含 BLE 连接层与界面。

## 这是什么

AndroidAPS 已经完成对 Equil 泵的协议逆向。本包把其中**与 Android 无关的纯逻辑**搬成 Swift：

- 链路层：CRC、帧编解码、收帧校验
- AES 域：GCM 加解密、命令基类与两阶段握手
- 命令集：绑定 / 解绑 / 设备信息 / 时间 / 运行模式 / TBR / 大剂量 / 药量
- 官方明文域：帧构造（设备查询等）

**不含**：Core Bluetooth 连接管理、后台调度、存储、界面。这些在后续的泵驱动层实现。

## 协议要点（必须遵守）

1. **跳过 CCC**：不写 f001 的 2902 描述符，泵才应答业务域帧。`preferNoCccSubscription` 标记此画像。
2. **不 createBond**：泵不需要蓝牙配对，配对会触发握手超时。
3. **命令明文**：禁用原生加密库（对 Equil 返回垃圾值），协议全程明文。
4. **用完即走**：每次操作临时绑定、完成后解绑断连，官方控制器可随时接管。

细节见 `docs/08-AAPS可借鉴逻辑清单.md` 与 AndroidAPS 项目内的协议手册/移植任务书。

## 结构

```
Sources/EquilKit/
├── Support/
│   ├── EquilBytes.swift          Hex 编解码 + 小端整数（对照 Utils.kt）
│   └── BasalSchedule.swift       基础率表（对照 BasalSchedule/Entry）
├── Protocol/
│   ├── LinkLayer.swift           crc8Maxim / crc16 / 帧校验
│   ├── EquilTypes.swift          EquilResponse / EquilCmdModel / 错误
│   ├── EquilAES.swift            AES-GCM（CryptoKit）
│   └── OfficialFrame.swift       官方明文域帧
├── Commands/
│   ├── EquilContext.swift        常量 / 计数器 / 设置存储协议
│   ├── BaseCmd.swift             链路层分帧 + 收帧还原
│   ├── BaseSetting.swift         AES 域两阶段命令基类
│   ├── PairCommands.swift        CmdPair / CmdUnPair
│   ├── ReadCommands.swift        DevicesGet / ModelGet / InsulinGet / TempBasalGet / DevicesOldGet
│   ├── WriteCommands.swift       TimeSet / ModelSet / TempBasalSet / LargeBasalSet
│   ├── BasalCommands.swift       CmdBasalGet / CmdBasalSet（基础率表读写）
│   ├── SettingCommands.swift     CmdAlarmSet / CmdBolusRateSet / CmdSettingSet
│   ├── HistoryCommands.swift     CmdHistoryGet / CmdInsulinChange / CmdExtendedBolusSet
│   └── PositioningCommands.swift CmdStepSet / CmdResistanceGet（推杆定位循环）
├── BLE/
│   ├── EquilGatt.swift           GATT 标识（f000 / f001 / 2902）
│   ├── EquilTransport.swift      传输抽象 + 事件 + 可取消定时器
│   ├── EquilLinkController.swift 链路状态机（对照 EquilBLE.kt）
│   └── CoreBluetoothTransport.swift  Core Bluetooth 实现（iOS/macOS）
└── Official/
    ├── OfficialCommand.swift     官方域命令基类（op5/op6 确认状态机）
    ├── OfficialCommands.swift    官方域命令子类（设备/时间/推杆/状态/TBR/大剂量）
    └── OfficialSession.swift     官方域会话游标（token 回显链）
```

## 测试

```sh
swift test
```

- `CRCTests`：crc8Maxim 对照 8 个实测官方帧样本（与 `tools/verify_protocol.py` 交叉验证）。
- `LinkLayerTests`：帧构造与校验。
- `AESTests`：密钥派生与 GCM 往返。
- `CommandTests`：命令载荷字节布局、收帧还原、分帧结构。
- `OfficialCommandTests`：官方域帧构造对照协议手册实测样本，op5/op6 确认状态机与 ACK 生成。
- `RemainingCommandTests`：历史记录 / 推杆定位 / 换药 / 扩展大剂量 / 旧设备查询的载荷与解析。
- `LinkControllerTests`：用假传输层驱动链路状态机（画像配置、服务缺失断开、首帧写出与 CRC、收帧路由、订阅路径）；`EquilTimer` 取消/替换语义。

## 尚未移植

AES 域与官方域命令集已全部落地（对照 AAPS 的 `manager/command/` 与 `official/`）。
以下两项在 AAPS 侧即无协议实现，故不移植：

- `CmdStatusGet`：AAPS 中仅是 `CustomCommand` 队列标记（无报文），状态/报警的实时解析在 BLE 层与官方域完成。
- `CmdMaxBasalRateSet`：AAPS 源文件为空（0 字节），最大基础率仅作为偏好键约束（`EquilMaxBasalRate`，1.0–35.0，默认 20.0）。

仍待补的功能层：

- 官方域应答的 GATT Server 回传通道（iOS 侧对应 `CBPeripheralManager`），见下方待验证项。
- 状态/报警字段语义标定（`OfficialStatusQuery` / `OfficialParam3Read` / `OfficialParam4Read` 先记录原始数据，待真机标定）。

## 待验证

- **CCC 画像冲突（最关键）**：AAPS 结论是"不写 f001 的 2902 描述符，泵才进控制端口(4/5)"；
  但 iOS 只能用 `setNotifyValue` 订阅，该调用必然写 2902。若该结论成立，iOS 无法在不写
  CCC 的前提下收通知，官方域命令会超时——需真机验证，或改用 GATT Server 收应答。
  详见 [iOS BLE 移植说明](../docs/09-iOS%20BLE%20移植说明.md)。
- `BaseCmd.decodeModel` 的收帧索引（首帧末 4 字节、续帧 [6..]）按 AAPS 原样移植，
  需用真实收帧日志再核对一次。
- `responseCmd` 分帧的末帧长度语义已按 AAPS 逐行复刻，建议抓一次真机写入日志比对。
- 广播数据解析（电池/药量）在 AAPS 走 `scanRecord.bytes`；iOS 只能取
  `CBAdvertisementDataManufacturerData` / `ServiceData`，字段对齐需真机标定。

## 构建前提

本包需要 Swift 工具链（Mac 上的 Xcode，或 macOS/Linux 的 swift 命令行）。
`BLE/CoreBluetoothTransport.swift` 用 `#if canImport(CoreBluetooth)` 包裹，
在无 Core Bluetooth 的平台自动剔除。当前开发机为 Windows，无法编译，需在 Mac 上执行 `swift test`。