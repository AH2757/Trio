import Foundation
import LoopKit
import EquilKit

/// 基础率表条目（可持久化）。与 `EquilKit.BasalScheduleEntry` 语义一致，
/// 但额外实现 `Codable` 以便写入 LoopKit 的 `RawStateValue`。
public struct EquilBasalEntry: Codable, Equatable {
    /// 距零点秒数。
    public var startTimeSeconds: Int
    /// 速率（U/h）。
    public var rate: Double

    public init(startTimeSeconds: Int, rate: Double) {
        self.startTimeSeconds = startTimeSeconds
        self.rate = rate
    }
}

/// 泵端报警/事件，供驱动层生成 LoopKit `Alert` 与历史记录。
///
/// 字段语义来自 AAPS 广播解码（协议硬知识 #9、#14）：广播 28 字节含
/// 电池[17]/药量[18]/速率[19-20]/历史索引[23-24]/事件[25-27]。
public struct EquilAlarm: Codable, Equatable {

    public enum Kind: String, Codable {
        /// 堵管（推杆阻力超阈值）。
        case occlusion
        /// 低电量。
        case lowBattery
        /// 低药量。
        case lowReservoir
        /// 推杆回退（(4,8,0)）。
        case pushrodRewind
        /// 异常断电重启（(5,1,0)）。
        case powerLoss
        case unknown
    }

    public var kind: Kind
    /// 原始事件码（广播 [25..27] 或历史 type/level/parm）。
    public var code: Int
    public var occurredAt: Date
    public var message: String

    public init(kind: Kind, code: Int, occurredAt: Date, message: String) {
        self.kind = kind
        self.code = code
        self.occurredAt = occurredAt
        self.message = message
    }

    /// 供 LoopKit `Alert.AlertIdentifier` 使用的稳定标识。
    public var alertIdentifier: String { "equil.\(kind.rawValue)" }
}

/// Equil 泵的完整可持久化状态。
///
/// 对照 `MedtrumPumpState` 的组织方式，直接实现 `RawRepresentable` 以对接
/// LoopKit 的 `PumpManager.RawStateValue`（`[String: Any]`）。
///
/// 注意：`boundToPump` / `isConnected` 等连接期瞬态**不持久化**——
/// 对照 AAPS，App 重启一律视为未绑定（用完即走架构的前提）。
public class EquilPumpState: RawRepresentable {
    public typealias RawValue = PumpManager.RawStateValue

    // MARK: - 配对信息

    /// 是否完成向导。
    public var isOnboarded: Bool
    /// 泵号，6 位 hex（如 "D02563"）。
    public var serialNumber: String
    /// 用户输入的 6 位数字配对密码（明文，AAPS 同样明文存 SP）。
    public var password: String
    /// 广播名（如 "Equil - D02563"）。
    public var deviceName: String
    /// Core Bluetooth 外设标识（每台手机稳定，跨手机不同）。
    public var peripheralIdentifier: UUID?
    /// 固件版本（如 "1.3"）。
    public var firmwareVersion: String?
    /// CmdPair 写回的设备标识（AAPS `equilDevices`，64 位 hex）。
    public var deviceToken: String
    /// CmdPair 写回的会话密码（AAPS `equilPassword`，64 位 hex）。
    public var sessionPassword: String

    // MARK: - 运行状态

    /// RunMode 原始值：0 暂停 / 1 运行 / 2 停止。
    public var runModeRaw: Int
    /// 泵是否已初始化（对照 AAPS `key_equil_pump_initialized`）。
    public var isPumpInitialized: Bool
    public var insulinType: InsulinType?

    // MARK: - 遥测

    /// 剩余药量（U）。
    public var reservoirUnits: Double
    /// 电量百分比（0–100）。
    public var batteryPercent: Double
    /// 最后一次成功同步（泵数据可信到此刻）。
    public var lastSync: Date
    /// 最后一次与泵通信（含广播），用于连接状态三态显示。
    public var lastCommunication: Date?
    /// 24 段基础率表。
    public var basalSchedule: [EquilBasalEntry]
    /// 大剂量输注速率枚举（见 `EquilConst.bolusRateDefault`）。
    public var bolusRate: Int
    /// 单次最大大剂量（U），来自 DeliveryLimits。
    public var maxBolusUnits: Double?
    /// 最大基础率（U/h），来自 DeliveryLimits。
    public var maxBasalRateUnitsPerHour: Double?

    // MARK: - 历史同步游标

    /// 泵端最新历史游标（来自广播 `historyIndex`）。
    public var historyIndex: Int
    /// 本机已同步到的历史游标（对照 AAPS `startHistoryIndex`）。
    public var startHistoryIndex: Int

    // MARK: - 剂量跟踪

    public var bolusDose: UnfinalizedDose?
    public var basalDose: UnfinalizedDose
    public var cancelingBolusSince: Date?

    // MARK: - 报警

    public var lastAlarm: EquilAlarm?

    /// 取消大剂量的"进行中"标记有效期（长于一次写超时+重连）。
    private static let cancelBolusTimeout: TimeInterval = .minutes(2)

    private var isCancelingBolus: Bool {
        guard let since = cancelingBolusSince else { return false }
        return Date.now.timeIntervalSince(since) < Self.cancelBolusTimeout
    }

    // MARK: - 初始化

    public init(
        serialNumber: String = "",
        password: String = "",
        insulinType: InsulinType? = nil,
        basalSchedule: [EquilBasalEntry] = EquilPumpState.defaultBasalSchedule
    ) {
        isOnboarded = false
        self.serialNumber = serialNumber
        self.password = password
        deviceName = serialNumber.isEmpty ? "" : "Equil - \(serialNumber)"
        peripheralIdentifier = nil
        firmwareVersion = nil
        deviceToken = ""
        sessionPassword = ""
        runModeRaw = RunMode.stop.rawValue
        isPumpInitialized = false
        self.insulinType = insulinType
        reservoirUnits = 0
        batteryPercent = 0
        lastSync = .distantPast
        lastCommunication = nil
        self.basalSchedule = basalSchedule
        bolusRate = EquilConst.bolusRateDefault
        maxBolusUnits = nil
        maxBasalRateUnitsPerHour = nil
        historyIndex = 0
        startHistoryIndex = 0
        bolusDose = nil
        basalDose = UnfinalizedDose(basalRate: 0, insulinType: insulinType)
        cancelingBolusSince = nil
        lastAlarm = nil
    }

    public required init(rawValue: RawValue) {
        isOnboarded = rawValue["isOnboarded"] as? Bool ?? false
        serialNumber = rawValue["serialNumber"] as? String ?? ""
        password = rawValue["password"] as? String ?? ""
        deviceName = rawValue["deviceName"] as? String ?? ""
        peripheralIdentifier = (rawValue["peripheralIdentifier"] as? String).flatMap { UUID(uuidString: $0) }
        firmwareVersion = rawValue["firmwareVersion"] as? String
        deviceToken = rawValue["deviceToken"] as? String ?? ""
        sessionPassword = rawValue["sessionPassword"] as? String ?? ""
        runModeRaw = rawValue["runModeRaw"] as? Int ?? RunMode.stop.rawValue
        isPumpInitialized = rawValue["isPumpInitialized"] as? Bool ?? false
        reservoirUnits = rawValue["reservoirUnits"] as? Double ?? 0
        batteryPercent = rawValue["batteryPercent"] as? Double ?? 0
        lastSync = rawValue["lastSync"] as? Date ?? .distantPast
        lastCommunication = rawValue["lastCommunication"] as? Date
        bolusRate = rawValue["bolusRate"] as? Int ?? EquilConst.bolusRateDefault
        maxBolusUnits = rawValue["maxBolusUnits"] as? Double
        maxBasalRateUnitsPerHour = rawValue["maxBasalRateUnitsPerHour"] as? Double
        historyIndex = rawValue["historyIndex"] as? Int ?? 0
        startHistoryIndex = rawValue["startHistoryIndex"] as? Int ?? 0
        cancelingBolusSince = rawValue["cancelingBolusSince"] as? Date

        if let rawInsulinType = rawValue["insulinType"] as? InsulinType.RawValue {
            insulinType = InsulinType(rawValue: rawInsulinType)
        } else {
            insulinType = nil
        }

        if let rawSchedule = rawValue["basalSchedule"] as? [[String: Any]] {
            basalSchedule = rawSchedule.compactMap { dict in
                guard let start = dict["startTimeSeconds"] as? Int,
                      let rate = dict["rate"] as? Double else { return nil }
                return EquilBasalEntry(startTimeSeconds: start, rate: rate)
            }
        } else {
            basalSchedule = EquilPumpState.defaultBasalSchedule
        }
        if basalSchedule.isEmpty {
            basalSchedule = EquilPumpState.defaultBasalSchedule
        }

        bolusDose = (rawValue["bolusDose"] as? UnfinalizedDose.RawValue).flatMap { UnfinalizedDose(rawValue: $0) }
        if let rawBasal = rawValue["basalDose"] as? UnfinalizedDose.RawValue,
           let dose = UnfinalizedDose(rawValue: rawBasal) {
            basalDose = dose
        } else {
            // `currentBaseBasalRate` is a computed property, so it cannot be read from `self`
            // while `basalDose` (the last stored property) is still uninitialized.
            let startOfDay = Calendar.current.startOfDay(for: Date())
            let offset = Int(Date().timeIntervalSince(startOfDay))
            let rate = basalSchedule.last(where: { $0.startTimeSeconds <= offset })?.rate ?? 0
            basalDose = UnfinalizedDose(basalRate: rate, insulinType: insulinType)
        }

        if let rawAlarm = rawValue["lastAlarm"] as? [String: Any] {
            lastAlarm = EquilAlarm(
                kind: EquilAlarm.Kind(rawValue: rawAlarm["kind"] as? String ?? "") ?? .unknown,
                code: rawAlarm["code"] as? Int ?? 0,
                occurredAt: rawAlarm["occurredAt"] as? Date ?? .distantPast,
                message: rawAlarm["message"] as? String ?? ""
            )
        } else {
            lastAlarm = nil
        }
    }

    public var rawValue: RawValue {
        var value: [String: Any] = [:]
        value["isOnboarded"] = isOnboarded
        value["serialNumber"] = serialNumber
        value["password"] = password
        value["deviceName"] = deviceName
        value["peripheralIdentifier"] = peripheralIdentifier?.uuidString
        value["firmwareVersion"] = firmwareVersion
        value["deviceToken"] = deviceToken
        value["sessionPassword"] = sessionPassword
        value["runModeRaw"] = runModeRaw
        value["isPumpInitialized"] = isPumpInitialized
        value["insulinType"] = insulinType?.rawValue
        value["reservoirUnits"] = reservoirUnits
        value["batteryPercent"] = batteryPercent
        value["lastSync"] = lastSync
        value["lastCommunication"] = lastCommunication
        value["bolusRate"] = bolusRate
        value["maxBolusUnits"] = maxBolusUnits
        value["maxBasalRateUnitsPerHour"] = maxBasalRateUnitsPerHour
        value["historyIndex"] = historyIndex
        value["startHistoryIndex"] = startHistoryIndex
        value["cancelingBolusSince"] = cancelingBolusSince
        value["basalSchedule"] = basalSchedule.map { ["startTimeSeconds": $0.startTimeSeconds, "rate": $0.rate] }
        value["bolusDose"] = bolusDose?.rawValue
        value["basalDose"] = basalDose.rawValue
        if let alarm = lastAlarm {
            value["lastAlarm"] = [
                "kind": alarm.kind.rawValue,
                "code": alarm.code,
                "occurredAt": alarm.occurredAt,
                "message": alarm.message
            ]
        }
        return value
    }

    // MARK: - 派生

    /// 默认基础率表：24 段全 0。
    public static var defaultBasalSchedule: [EquilBasalEntry] {
        (0..<24).map { EquilBasalEntry(startTimeSeconds: $0 * 3600, rate: 0) }
    }

    public var runMode: RunMode { RunMode(rawValue: runModeRaw) ?? .stop }

    public var currentBaseBasalRate: Double {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let offset = Int(Date().timeIntervalSince(startOfDay))
        return basalSchedule.last(where: { $0.startTimeSeconds <= offset })?.rate ?? 0
    }

    /// 转换成 `EquilKit.BasalSchedule`（命令层写入用）。
    public var equilBasalSchedule: BasalSchedule {
        let entries = basalSchedule.map {
            BasalScheduleEntry(rate: $0.rate, startTimeSeconds: $0.startTimeSeconds)
        }
        return BasalSchedule(entries: entries.isEmpty ? [BasalScheduleEntry(rate: 0, startTimeSeconds: 0)] : entries)
    }

    public var basalDeliveryState: PumpManagerStatus.BasalDeliveryState {
        switch basalDose.type {
        case .tempBasal:
            return .tempBasal(basalDose.toDoseEntry(isMutable: true))
        case .suspend:
            return .suspended(basalDose.startDate)
        default:
            return .active(basalDose.startDate)
        }
    }

    public var bolusDeliveryState: PumpManagerStatus.BolusState {
        if isCancelingBolus { return .canceling }
        guard let dose = bolusDose?.toDoseEntry(isMutable: true) else { return .noBolus }
        return .inProgress(dose)
    }

    /// 是否处于可下发剂量的运行态（对照 AAPS：RunMode == RUN）。
    public var isRunning: Bool { runMode == .run }

    public var debugDescription: String {
        [
            "## EquilPumpState - \(Date.now)",
            "* isOnboarded: \(isOnboarded)",
            "* serialNumber: \(serialNumber)",
            "* deviceName: \(deviceName)",
            "* peripheralIdentifier: \(peripheralIdentifier?.uuidString ?? "nil")",
            "* firmwareVersion: \(firmwareVersion ?? "nil")",
            "* runMode: \(runModeRaw)",
            "* isPumpInitialized: \(isPumpInitialized)",
            "* reservoirUnits: \(reservoirUnits)",
            "* batteryPercent: \(batteryPercent)",
            "* lastSync: \(lastSync)",
            "* lastCommunication: \(String(describing: lastCommunication))",
            "* bolusRate: \(bolusRate)",
            "* insulinType: \(String(describing: insulinType))",
            "* basalDose: \(basalDose.type)",
            "* bolusDose: \(bolusDose == nil ? "nil" : "in-progress")"
        ].joined(separator: "\n")
    }
}