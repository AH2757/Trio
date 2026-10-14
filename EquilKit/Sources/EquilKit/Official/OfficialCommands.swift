import Foundation

/// 官方域命令集合，对照 AndroidAPS `official/OfficialCommands.kt`。
///
/// 覆盖设备查询、时间同步、推杆回退/步进、状态/基础率/参数读取、运行模式、TBR 与大剂量。
/// 每条命令的端口、op、param、数据编码均按 AAPS 实测日志固化，勿随意改动。

// MARK: - 设备查询

/// 设备查询：端口 0/0，op2/param0，Data=`00 00 00 00`。
/// 应答 data（与 RF 广播设备信息一致）：
/// `SN(6B) + 00 02 01 00 00 00 + fw(2B: major.minor) + 01 01 D0 07 00 00`
public final class OfficialDeviceQuery: OfficialCommand {

    public override var srcPort: Int { OfficialFrame.portDevice }
    public override var dstPort: Int { OfficialFrame.portDevice }
    public override var operation: Int { OfficialFrame.opRead }
    public override var parameter: Int { 0 }
    /// 4B 全零（官方 Length:4 实证，2B 会被泵静默丢弃）。
    public override var commandData: [UInt8] { [0x00, 0x00, 0x00, 0x00] }
    public override var completesByNotify: Bool { true }
    /// 官方四日志查询帧 token 字节级恒定（SDK 硬编码源标识，泵校验）。
    public override var fixedToken: Int? { 0x71E5 }

    public private(set) var serialNumberHex: String?
    public private(set) var firmwareVersion: String?

    public override func onResponse(_ data: [UInt8]) {
        guard data.count >= 14 else { return }
        serialNumberHex = Hex.encode(Array(data[0..<6]))
        let fw = "\(data[12]).\(data[13])"
        firmwareVersion = fw
        EquilLog.info("OfficialDeviceQuery: sn=\(serialNumberHex ?? "") fw=\(fw)")
    }

    /// 固件版本是否达到最低支持线。
    public func isSupport() -> Bool {
        (Float(firmwareVersion ?? "0") ?? 0) >= EquilConst.supportLevel
    }
}

// MARK: - 时间同步

/// 时间同步：端口 5/5，op1/param0，Data=yy MM dd HH mm ss（6B）。
/// 完成信号：泵 op6/param0。
public final class OfficialTimeSet: OfficialCommand {

    private let timeBytes: [UInt8]

    public init(settings: EquilSettingsStore, now: Date = Date()) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        timeBytes = [
            UInt8((c.year ?? 0) % 100),
            UInt8(c.month ?? 0),
            UInt8(c.day ?? 0),
            UInt8(c.hour ?? 0),
            UInt8(c.minute ?? 0),
            UInt8(c.second ?? 0)
        ]
        super.init(createTime: Int64(now.timeIntervalSince1970 * 1000), settings: settings)
    }

    public override var srcPort: Int { OfficialFrame.portTherapy }
    public override var dstPort: Int { OfficialFrame.portTherapy }
    public override var operation: Int { OfficialFrame.opWrite }
    public override var parameter: Int { 0 }
    public override var commandData: [UInt8] { timeBytes }
    /// 等泵 op6/param0 完成应答并回 op0/param0 ACK。
    public override var acksDone: Bool { true }
}

// MARK: - 推杆回退 / 步进

/// 推杆回退（rewind）：端口 4/4，op1/param6，Data=LE u32 回退步数。
/// 官方帧实证 `01 06 00 7D`（32000），泵回 op6/param6/data=01 后立即触发 rewinding。
/// 更换储药器流程的第一步即发送此命令。
public final class OfficialConfigSet: OfficialCommand {

    private let maxSteps: Int

    public init(settings: EquilSettingsStore, maxSteps: Int = EquilConst.stepMax) {
        self.maxSteps = maxSteps
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
    }

    public override var srcPort: Int { OfficialFrame.portConfig }
    public override var dstPort: Int { OfficialFrame.portConfig }
    public override var operation: Int { OfficialFrame.opWrite }
    public override var parameter: Int { 6 }
    public override var commandData: [UInt8] { EquilBytes.intToBytes(maxSteps) }
    /// 等泵 op6/param6 完成应答并回 op0/param6 ACK。
    public override var acksDone: Bool { true }
}

/// 推杆步进：端口 4/4，op1/param7，Data=LE u32 步数。
/// 实测 `50 00` = 80 步；换药/排气步数复用 `EquilConst.stepFill(160)` / `stepAir(120)`。
public final class OfficialPushrodStep: OfficialCommand {

    private let steps: Int

    public init(settings: EquilSettingsStore, steps: Int) {
        self.steps = steps
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
    }

    public override var srcPort: Int { OfficialFrame.portConfig }
    public override var dstPort: Int { OfficialFrame.portConfig }
    public override var operation: Int { OfficialFrame.opWrite }
    public override var parameter: Int { 7 }
    /// LE u32 步数（官方 `50 00`+续 `00 00` = 4B 实证）。
    public override var commandData: [UInt8] { EquilBytes.intToBytes(steps) }
    /// 完成信号兼容 op6 与 op5/param7（日志中两种均出现）。
    public override var completesByNotify: Bool { true }
    /// 泵 op6/param7 完成应答须回 op0/param7 ACK（data=01）——官方推杆循环 idx 步进的关键。
    public override var acksDone: Bool { true }
}

// MARK: - 状态 / 基础率 / 参数读取

/// 状态查询：端口 4/4，op2/param0（实测帧 `… 04 04 … 02 00` len=0x0E）。
/// 应答 data 字段语义部分未标定——先记录原始数据供真机标定。
public final class OfficialStatusQuery: OfficialCommand {

    public override var srcPort: Int { OfficialFrame.portConfig }
    public override var dstPort: Int { OfficialFrame.portConfig }
    public override var operation: Int { OfficialFrame.opRead }
    public override var parameter: Int { 0 }
    public override var completesByNotify: Bool { true }
    /// 配对握手状态查询（4/4 op2/param0 空数据）：泵 op5/param0 应答无 ACK。
    public override var acksNotify: Bool { false }

    public private(set) var statusData: [UInt8]?

    public override func onResponse(_ data: [UInt8]) {
        statusData = data
        EquilLog.info("OfficialStatusQuery data=\(Hex.encode(data)) (\(data.count)B) — 字段语义待真机标定")
    }
}

/// 基础率表读取（只读安全）：端口 4/4，op2/param2。
/// - `empty=true`（配对握手形态）：Data=空，应答回 op0/param2 ACK。
/// - `empty=false`（同步流形态）：Data=`FF`，应答 40B = 24 段 × LE u16，不回 ACK。
public final class OfficialBasalRead: OfficialCommand {

    private let empty: Bool
    private let flowStart: Bool

    public init(settings: EquilSettingsStore, empty: Bool = false, flowStart: Bool = false) {
        self.empty = empty
        self.flowStart = flowStart
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
    }

    public override var srcPort: Int { OfficialFrame.portConfig }
    public override var dstPort: Int { OfficialFrame.portConfig }
    public override var operation: Int { OfficialFrame.opRead }
    public override var parameter: Int { 2 }
    public override var commandData: [UInt8] { empty ? [] : [0xFF] }
    public override var completesByNotify: Bool { true }
    /// 配对握手形态回 ACK；同步流形态不回（idx0→1 直接推进）。
    public override var acksNotify: Bool { empty }
    /// 同步流入口形态：idx=00 + ack=0000。
    public override var fixedAckToken: Int? { flowStart ? 0x0000 : nil }
    public override var fixedIndex: Int? { flowStart ? 0x00 : nil }

    public private(set) var basalData: [UInt8]?

    public override func onResponse(_ data: [UInt8]) {
        basalData = data
        EquilLog.info("OfficialBasalRead data=\(Hex.encode(data)) (\(data.count)B)")
    }
}

/// TBR 状态读取：端口 4/4，op2/param4，Data=空。应答 op5/param4 不回 ACK。
public final class OfficialParam4Read: OfficialCommand {

    public override var srcPort: Int { OfficialFrame.portConfig }
    public override var dstPort: Int { OfficialFrame.portConfig }
    public override var operation: Int { OfficialFrame.opRead }
    public override var parameter: Int { 4 }
    public override var commandData: [UInt8] { [] }
    public override var completesByNotify: Bool { true }
    public override var acksNotify: Bool { false }

    public private(set) var param4Data: [UInt8]?

    public override func onResponse(_ data: [UInt8]) {
        param4Data = data
        EquilLog.info("OfficialParam4Read data=\(Hex.encode(data)) (\(data.count)B)")
    }
}

/// param3 读取：端口 4/4，op2/param3，Data=空。应答 op5/param3 回 op0/param3 ACK。
public final class OfficialParam3Read: OfficialCommand {

    public override var srcPort: Int { OfficialFrame.portConfig }
    public override var dstPort: Int { OfficialFrame.portConfig }
    public override var operation: Int { OfficialFrame.opRead }
    public override var parameter: Int { 3 }
    public override var commandData: [UInt8] { [] }
    public override var completesByNotify: Bool { true }
    public override var acksNotify: Bool { true }

    public private(set) var param3Data: [UInt8]?

    public override func onResponse(_ data: [UInt8]) {
        param3Data = data
        EquilLog.info("OfficialParam3Read data=\(Hex.encode(data)) (\(data.count)B)")
    }
}

/// 推杆进度查询：端口 4→15，op2/param2（官方推杆流全程实证）。
/// - 配对入口（链式）：`emptyData=true` 空数据。
/// - 循环内查询 Data=`FF`；终止查询 Data=空。
/// - `flowStart=true` 为流程起始形态：idx=00 + ack=0000。
public final class OfficialPushrodStatusQuery: OfficialCommand {

    private let flowStart: Bool
    private let terminating: Bool
    private let emptyData: Bool

    public init(settings: EquilSettingsStore, flowStart: Bool = false, terminating: Bool = false, emptyData: Bool = false) {
        self.flowStart = flowStart
        self.terminating = terminating
        self.emptyData = emptyData
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
    }

    public override var srcPort: Int { OfficialFrame.portConfig }
    public override var dstPort: Int { 0x15 }
    public override var operation: Int { OfficialFrame.opRead }
    public override var parameter: Int { 2 }
    public override var commandData: [UInt8] { (terminating || emptyData) ? [] : [0xFF] }
    public override var completesByNotify: Bool { true }
    /// 循环内状态查询（op5/param2）官方不回 ACK；终止查询的应答官方回 op0/param2。
    public override var acksNotify: Bool { terminating }
    /// 推杆流入口形态：idx=00 + ack=0000。
    public override var fixedAckToken: Int? { flowStart ? 0x0000 : nil }
    public override var fixedIndex: Int? { flowStart ? 0x00 : nil }

    public private(set) var statusData: [UInt8]?

    public override func onResponse(_ data: [UInt8]) {
        statusData = data
        EquilLog.info("OfficialPushrodStatusQuery data=\(Hex.encode(data)) (\(data.count)B)")
    }
}

// MARK: - 治疗类写入

/// 运行模式：端口 4/4，op1/param0，Data=LE u32。
/// 编码与 AES 域 RunMode.command 完全对齐（1=RUN, 0=SUSPEND, 2=STOP）。
public final class OfficialRunModeSet: OfficialCommand {

    private let mode: Int

    public init(settings: EquilSettingsStore, mode: Int) {
        self.mode = mode
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
    }

    public override var srcPort: Int { OfficialFrame.portConfig }
    public override var dstPort: Int { OfficialFrame.portConfig }
    public override var operation: Int { OfficialFrame.opWrite }
    public override var parameter: Int { 0 }
    public override var commandData: [UInt8] { EquilBytes.intToBytes(mode) }
    /// 新会话语义：官方激活帧 ack=0000 + idx=00（帧 [4..5]=00 4A 恒定）。
    public override var fixedAckToken: Int? { 0x0000 }
    public override var fixedIndex: Int? { 0x00 }
}

/// 临时基础率：端口 4/4，op1/param4，Data=LE u32×2 [速率×80, 时长秒]。
/// 实证：TBR 0.5U/h 30min → [40, 1800]；0.6U/h 30min → [48, 1800]；取消 → [0, 0]。
public final class OfficialTempBasalSet: OfficialCommand {

    private let rate: Double
    private let durationMinutes: Int
    private let cancel: Bool

    public init(settings: EquilSettingsStore, rate: Double, durationMinutes: Int, cancel: Bool) {
        self.rate = rate
        self.durationMinutes = durationMinutes
        self.cancel = cancel
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
    }

    public override var srcPort: Int { OfficialFrame.portConfig }
    public override var dstPort: Int { OfficialFrame.portConfig }
    public override var operation: Int { OfficialFrame.opWrite }
    public override var parameter: Int { 4 }
    public override var commandData: [UInt8] {
        if cancel { return [UInt8](repeating: 0, count: 8) } // 全零 = 取消 TBR
        return EquilBytes.concat(
            EquilBytes.intToBytes(Int((rate * 80).rounded())),
            EquilBytes.intToBytes(durationMinutes * 60)
        )
    }
    /// 官方 TBR 帧独立流程形态：ack=0000 + idx=00。
    public override var fixedAckToken: Int? { 0x0000 }
    public override var fixedIndex: Int? { 0x00 }
}

/// 大剂量：端口 4/4，op1/param3，Data=LE u32×4 [剂量×160, 速率×10, 0, 0]。
/// 实证：1.00U → [160, 20, 0, 0]（速率 20=2.0U/min）。
/// 注意：剂量系数 160/U 为单样本推断——真机首测请用小剂量（0.05U）验证。
public final class OfficialBolusSet: OfficialCommand {

    private let insulin: Double
    private let rateX10: Int

    public init(settings: EquilSettingsStore, insulin: Double, rateX10: Int = EquilConst.bolusRateDefault) {
        self.insulin = insulin
        self.rateX10 = rateX10
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
    }

    public override var srcPort: Int { OfficialFrame.portConfig }
    public override var dstPort: Int { OfficialFrame.portConfig }
    public override var operation: Int { OfficialFrame.opWrite }
    public override var parameter: Int { 3 }
    public override var commandData: [UInt8] {
        EquilBytes.concat(
            EquilBytes.intToBytes(Int((insulin * 160).rounded())),
            EquilBytes.intToBytes(rateX10),
            EquilBytes.intToBytes(0),
            EquilBytes.intToBytes(0)
        )
    }
}