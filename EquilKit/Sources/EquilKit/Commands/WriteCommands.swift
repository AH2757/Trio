import Foundation

/// 运行模式，对照 AndroidAPS `data/RunMode`。
public enum RunMode: Int {
    case suspend = 0
    case run = 1
    case stop = 2
}

/// 大剂量类型，对照 AndroidAPS `database/BolusType`。
public enum BolusType {
    case `default`
    case fast
}

/// 时间同步，对照 AndroidAPS `manager/command/CmdTimeSet.kt`。
public final class CmdTimeSet: BaseSetting {

    public init(settings: EquilSettingsStore) {
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
        port = "0505"
    }

    public override var preferNoCccSubscription: Bool { true }

    public override func getFirstData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        var time = [UInt8](repeating: 0, count: 6)
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        time[0] = UInt8(((c.year ?? 2000) - 2000) & 0xFF)
        time[1] = UInt8((c.month ?? 1) & 0xFF)
        time[2] = UInt8((c.day ?? 1) & 0xFF)
        time[3] = UInt8((c.hour ?? 0) & 0xFF)
        time[4] = UInt8((c.minute ?? 0) & 0xFF)
        time[5] = UInt8((c.second ?? 0) & 0xFF)
        let data = EquilBytes.concat(indexByte, [0x01, 0x00], time)
        EquilCounters.pumpReqIndex += 1
        return data
    }

    public override func getNextData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let data = EquilBytes.concat(indexByte, [0x00, 0x00, 0x01])
        EquilCounters.pumpReqIndex += 1
        return data
    }

    public override func decodeConfirmData(_ data: [UInt8]) {
        markDone()
    }

    public override func getEventType() -> EquilEventType? { .setTime }
}

/// 设置运行模式（暂停/运行/停止），对照 AndroidAPS `manager/command/CmdModelSet.kt`。
public final class CmdModelSet: BaseSetting {

    public let mode: Int

    public init(mode: Int, settings: EquilSettingsStore) {
        self.mode = mode
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
    }

    public override var preferNoCccSubscription: Bool { true }

    public var runMode: RunMode {
        switch mode {
        case 1: return .run
        case 2: return .stop
        default: return .suspend
        }
    }

    public override func getFirstData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let data = EquilBytes.concat(indexByte, [0x01, 0x00], EquilBytes.intToBytes(mode))
        EquilCounters.pumpReqIndex += 1
        return data
    }

    public override func getNextData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let data = EquilBytes.concat(indexByte, [0x00, 0x00, 0x01])
        EquilCounters.pumpReqIndex += 1
        return data
    }

    public override func decodeConfirmData(_ data: [UInt8]) {
        markDone()
    }

    public override func getEventType() -> EquilEventType? {
        switch runMode {
        case .run: return .resumeDelivery
        case .suspend: return .suspendDelivery
        case .stop: return nil
        }
    }
}

/// 设置临时基础率（TBR），对照 AndroidAPS `manager/command/CmdTempBasalSet.kt`。
///
/// `step = (insulin / 0.05 * 8) / 2`（先截断再整除 2），`pumpTime = duration * 60` 秒。
public final class CmdTempBasalSet: BaseSetting {

    public let insulin: Double
    public let duration: Int
    public let cancel: Bool
    public let step: Int
    public let pumpTime: Int

    public init(insulin: Double, duration: Int, cancel: Bool = false, settings: EquilSettingsStore) {
        self.insulin = insulin
        self.duration = duration
        self.cancel = cancel
        self.step = insulin != 0.0 ? Int(insulin / 0.05 * 8) / 2 : 0
        self.pumpTime = duration * 60
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
        timeOut = 4000
    }

    public override var preferNoCccSubscription: Bool { true }

    public override func getFirstData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let data = EquilBytes.concat(
            indexByte, [0x01, 0x04],
            EquilBytes.intToBytes(step),
            EquilBytes.intToBytes(pumpTime)
        )
        EquilCounters.pumpReqIndex += 1
        return data
    }

    public override func getNextData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let data = EquilBytes.concat(indexByte, [0x00, 0x04, 0x01], EquilBytes.intToBytes(0))
        EquilCounters.pumpReqIndex += 1
        return data
    }

    public override func decodeConfirmData(_ data: [UInt8]) {
        markDone()
    }

    public override func getEventType() -> EquilEventType? {
        cancel ? .cancelTemporaryBasal : .setTemporaryBasal
    }
}

/// 大剂量（bolus），对照 AndroidAPS `manager/command/CmdLargeBasalSet.kt`。
///
/// `step = round(insulin / 0.05 * 8)`；`stepTime = round(insulin * 60 / 输注速率)`，
/// 速率由 `settings.bolusRate`（枚举 ×10）决定。`insulin == 0` 表示取消。
public final class CmdLargeBasalSet: BaseSetting {

    public let insulin: Double
    public let bolusType: BolusType
    public let step: Int
    public let stepTime: Int

    public init(insulin: Double, bolusType: BolusType = .default, settings: EquilSettingsStore) {
        self.insulin = insulin
        self.bolusType = bolusType
        if insulin != 0.0 {
            let s = Int((insulin / 0.05 * 8).rounded())
            let runRate = Double(settings.bolusRate) / 10.0
            self.step = s
            self.stepTime = runRate != 0 ? Int((insulin * 60 / runRate).rounded()) : 0
        } else {
            self.step = 0
            self.stepTime = 0
        }
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
    }

    public override var preferNoCccSubscription: Bool { true }

    public override func getFirstData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let zero = EquilBytes.intToBytes(0)
        let data = EquilBytes.concat(
            indexByte, [0x01, 0x03],
            EquilBytes.intToBytes(step),
            EquilBytes.intToBytes(stepTime),
            zero, zero
        )
        EquilCounters.pumpReqIndex += 1
        return data
    }

    public override func getNextData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let data = EquilBytes.concat(indexByte, [0x00, 0x03, 0x01], EquilBytes.intToBytes(0))
        EquilCounters.pumpReqIndex += 1
        return data
    }

    public override func decodeConfirmData(_ data: [UInt8]) {
        markDone()
    }

    public override func getEventType() -> EquilEventType? {
        insulin == 0.0 ? .cancelBolus : .setBolus
    }
}