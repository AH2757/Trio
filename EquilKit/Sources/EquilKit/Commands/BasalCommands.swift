import Foundation

/// 读取基础率表并校验，对照 AndroidAPS `manager/command/CmdBasalGet.kt`。
///
/// 本地按 24 段构造期望的应答 hex，与泵回包逐字节比对，结果写入 `enacted`。
public final class CmdBasalGet: BaseSetting {

    /// 24 段基础率（U/h）。
    private let basalProfile: [Double]

    public init(basalProfile: [Double], settings: EquilSettingsStore) {
        self.basalProfile = basalProfile
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
    }

    public override func getFirstData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let data = EquilBytes.concat(indexByte, [0x02, 0x02])
        EquilCounters.pumpReqIndex += 1
        return data
    }

    public override func getNextData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let data = EquilBytes.concat(indexByte, [0x00, 0x02, 0x01])
        EquilCounters.pumpReqIndex += 1
        return data
    }

    public override func decodeConfirmData(_ data: [UInt8]) {
        EquilLog.debug("CmdBasalGet==\(Hex.encode(data))")
        var currentBasal = ""
        for i in 0..<24 {
            let value = basalProfile[i] / 2
            let bs = EquilBytes.basalToByteArray2(value)
            currentBasal += Hex.encode(bs)
            currentBasal += Hex.encode(bs)
        }
        let rspBasal = data.count > 6 ? Hex.encode(Array(data[6...])) : ""
        EquilLog.debug("CmdBasalGet expect=\(currentBasal) actual=\(rspBasal)")
        enacted = currentBasal == rspBasal
        markDone()
    }

    public override func getEventType() -> EquilEventType? { nil }
}

/// 写入基础率表，对照 AndroidAPS `manager/command/CmdBasalSet.kt`。
///
/// 每条目编码：`basalToByteArray(rate / 2)` 的 `[lo, hi, lo, hi]`（即高低字节各重复一次）。
public final class CmdBasalSet: BaseSetting {

    private let basalSchedule: BasalSchedule

    public init(basalSchedule: BasalSchedule, settings: EquilSettingsStore) {
        self.basalSchedule = basalSchedule
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
    }

    public override var preferNoCccSubscription: Bool { true }

    public override func getFirstData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        var list: [UInt8] = []
        for entry in basalSchedule.entries {
            let value = entry.rate / 2
            let bs = EquilBytes.basalToByteArray(value)
            list.append(bs[1])
            list.append(bs[0])
            list.append(bs[1])
            list.append(bs[0])
        }
        let data = EquilBytes.concat(indexByte, [0x01, 0x02], list)
        EquilCounters.pumpReqIndex += 1
        return data
    }

    public override func getNextData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let data = EquilBytes.concat(indexByte, [0x00, 0x02, 0x01])
        EquilCounters.pumpReqIndex += 1
        return data
    }

    public override func decodeConfirmData(_ data: [UInt8]) {
        // AAPS 在此写入 SP 的 EQUIL_BASAL_SET 标记；本移植由驱动层依据 cmdStatus 持久化。
        markDone()
    }

    public override func getEventType() -> EquilEventType? { .setBasalProfile }
}