import Foundation

/// 报警模式，对照 AndroidAPS `data/AlarmMode`。
public enum AlarmMode: Int {
    case mute = 0
    case tone = 1
    case shake = 2
    case toneAndShake = 3

    public var command: Int { rawValue }

    public static func fromInt(_ number: Int) -> AlarmMode {
        AlarmMode(rawValue: number) ?? .toneAndShake
    }
}

/// 报警模式设置，对照 AndroidAPS `manager/command/CmdAlarmSet.kt`。
public final class CmdAlarmSet: BaseSetting {

    public let mode: Int

    public init(mode: Int, settings: EquilSettingsStore) {
        self.mode = mode
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
    }

    public override func getFirstData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let data = EquilBytes.concat(indexByte, [0x01, 0x0b], EquilBytes.intToBytes(mode))
        EquilCounters.pumpReqIndex += 1
        return data
    }

    public override func getNextData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let data = EquilBytes.concat(indexByte, [0x00, 0x0b, 0x01])
        EquilCounters.pumpReqIndex += 1
        return data
    }

    public override func decodeConfirmData(_ data: [UInt8]) {
        markDone()
    }

    public override func getEventType() -> EquilEventType? {
        switch AlarmMode(rawValue: mode) {
        case .some(.mute): return .setAlarmMute
        case .some(.tone): return .setAlarmTone
        case .some(.toneAndShake): return .setAlarmToneAndShake
        case .some(.shake): return .setAlarmShake
        case .none: return nil
        }
    }
}

/// 大剂量输注速率设置，对照 AndroidAPS `manager/command/CmdBolusRateSet.kt`。
///
/// `rate` 为泵枚举值：0=1.5 U/min（默认），1=3 U/min（推断自官方控制器日志，需真机验证）。
public final class CmdBolusRateSet: BaseSetting {

    public let rate: Int

    public init(rate: Int, settings: EquilSettingsStore) {
        self.rate = rate
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
    }

    public override func getFirstData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        // 命令码推断自官方日志 Parameter:10，需真机验证。
        let data = EquilBytes.concat(indexByte, [0x01, 0x0a], EquilBytes.intToBytes(rate))
        EquilCounters.pumpReqIndex += 1
        return data
    }

    public override func getNextData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let data = EquilBytes.concat(indexByte, [0x00, 0x0a, 0x01])
        EquilCounters.pumpReqIndex += 1
        return data
    }

    public override func decodeConfirmData(_ data: [UInt8]) {
        markDone()
    }

    public override func getEventType() -> EquilEventType? { nil }
}

/// 泵设置写入，对照 AndroidAPS `manager/command/CmdSettingSet.kt`。
///
/// 写入低电量告警、大剂量阈值、基础率阈值、堵塞阈值、胰岛素单位等固定参数。
/// `isPairStep()=true`：每次连接重新构建。
public final class CmdSettingSet: BaseSetting {

    public private(set) var lowAlarm: Double = 0.0
    public private(set) var bolusThresholdStep: Int = EquilConst.blousThresholdStep
    public private(set) var basalThresholdStep: Int = 240

    public init(maxBolus: Double? = nil, maxBasalRate: Double? = nil, settings: EquilSettingsStore) {
        if let maxBolus = maxBolus {
            bolusThresholdStep = EquilBytes.decodeSpeedToUH(maxBolus)
        }
        if let maxBasalRate = maxBasalRate {
            basalThresholdStep = EquilBytes.decodeSpeedToUH(maxBasalRate)
        }
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
    }

    public override func getFirstData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let equilCmd: [UInt8] = [0x01, 0x05]
        let useTime = EquilBytes.intToBytes(0)
        let autoCloseTime = EquilBytes.intToBytes(0)
        let lowAlarmByte = EquilBytes.intToTwoBytes(1600)
        let fastBolus = EquilBytes.intToTwoBytes(0)
        let occlusion = EquilBytes.intToTwoBytes(2800)
        let insulinUnit = EquilBytes.intToTwoBytes(8)
        let basalThreshold = EquilBytes.intToTwoBytes(basalThresholdStep)
        let bolusThreshold = EquilBytes.intToTwoBytes(bolusThresholdStep)
        let data = EquilBytes.concat(
            indexByte, equilCmd, useTime, autoCloseTime,
            lowAlarmByte, fastBolus,
            occlusion, insulinUnit, basalThreshold, bolusThreshold
        )
        EquilCounters.pumpReqIndex += 1
        EquilLog.debug("CmdSettingSet data==\(Hex.encode(data))===\(lowAlarm)")
        return data
    }

    public override func getNextData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let data = EquilBytes.concat(indexByte, [0x00, 0x05, 0x01])
        EquilCounters.pumpReqIndex += 1
        return data
    }

    public override func decodeConfirmData(_ data: [UInt8]) {
        markDone()
    }

    public override func isPairStep() -> Bool { true }

    public override func getEventType() -> EquilEventType? { nil }
}