import Foundation

/// 读取历史记录，对照 AndroidAPS `manager/command/CmdHistoryGet.kt`。
///
/// 泵按 `currentIndex` 逐条回放历史。确认段是一整条历史记录的明文字段。
/// `currentIndex != 0` 时保留原始确认段（`rawHistoryData`）供驱动层解码入库；
/// `currentIndex == 0` 是"读取游标头"探测，不入库（对照 AAPS 的 `decodeHistory` 条件）。
public final class CmdHistoryGet: BaseSetting {

    /// 本次请求的历史游标。
    public let currentIndex: Int

    public private(set) var battery = 0
    public private(set) var medicine = 0
    public private(set) var rate = 0
    public private(set) var largeRate = 0
    public private(set) var year = 0
    public private(set) var month = 0
    public private(set) var day = 0
    public private(set) var hour = 0
    public private(set) var minute = 0
    public private(set) var second = 0
    public private(set) var index = 0
    public private(set) var type = 0
    public private(set) var level = 0
    public private(set) var parm = 0
    /// 泵回显的记录索引（下一条历史的游标）。
    public private(set) var resultIndex = 0
    /// `currentIndex != 0` 时的原始确认段，供驱动层解码历史事件。
    public private(set) var rawHistoryData: [UInt8]?

    public init(currentIndex: Int, settings: EquilSettingsStore) {
        self.currentIndex = currentIndex
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
        port = "0505"
        // v55：快速失败——单条历史应答 <1s，默认 10s 超时使失败轮次拖沓。
        timeOut = 3000
    }

    /// v39：跳过 CCC 写入——保持跳 CCC 客户端画像（该画像应答 AES 域帧）。
    public override var preferNoCccSubscription: Bool { true }

    public override func getFirstData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let data = EquilBytes.concat(indexByte, [0x02, 0x01], EquilBytes.intToBytes(currentIndex))
        EquilCounters.pumpReqIndex += 1
        return data
    }

    public override func getNextData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let data = EquilBytes.concat(indexByte, [0x00, 0x01, 0x01])
        EquilCounters.pumpReqIndex += 1
        return data
    }

    public override func decodeConfirmData(_ data: [UInt8]) {
        guard data.count >= 24 else {
            markDone()
            return
        }
        year = Int(data[6])
        month = Int(data[7])
        day = Int(data[8])
        hour = Int(data[9])
        minute = Int(data[10])
        second = Int(data[11])
        battery = Int(data[12])
        medicine = Int(data[13])
        rate = EquilBytes.bytesToInt(data[15], data[14])
        largeRate = EquilBytes.bytesToInt(data[17], data[16])
        index = EquilBytes.bytesToInt(data[19], data[18])
        type = Int(data[21])
        level = Int(data[22])
        parm = Int(data[23])
        if currentIndex != 0 {
            rawHistoryData = data
        }
        resultIndex = index
        EquilLog.debug("CmdHistoryGet index=\(index) rate=\(rate) largeRate=\(largeRate) type=\(type) level=\(level) parm=\(parm) data=\(Hex.encode(data))")
        markDone()
    }

    public override func getEventType() -> EquilEventType? { nil }
}

/// 换药（更换储药器），对照 AndroidAPS `manager/command/CmdInsulinChange.kt`。
///
/// 推杆回退 32000 步（换管），泵确认段回状态字节。
public final class CmdInsulinChange: BaseSetting {

    /// 泵回状态字节（AAPS 透传给 `setInsulinChange`）。
    public private(set) var status = 0

    public init(settings: EquilSettingsStore) {
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
    }

    /// v38：跳过 CCC 写入——断开重连后必须保持同一客户端画像。
    public override var preferNoCccSubscription: Bool { true }

    public override func getFirstData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let data = EquilBytes.concat(indexByte, [0x01, 0x06], EquilBytes.intToBytes(EquilConst.stepMax))
        EquilCounters.pumpReqIndex += 1
        return data
    }

    public override func getNextData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let data = EquilBytes.concat(indexByte, [0x00, 0x06, 0x01], EquilBytes.intToBytes(0))
        EquilCounters.pumpReqIndex += 1
        return data
    }

    public override func decodeConfirmData(_ data: [UInt8]) {
        if data.count > 6 {
            status = Int(data[6])
        }
        EquilLog.debug("CmdInsulinChange status=\(status) data=\(Hex.encode(data))")
        markDone()
    }

    public override func getEventType() -> EquilEventType? { .changeInsulin }
}

/// 扩展大剂量（方波），对照 AndroidAPS `manager/command/CmdExtendedBolusSet.kt`。
///
/// `step = (insulin / 0.05 * 8).toInt()`（向零截断，与 AAPS 的 Double 语义一致），
/// `pumpTime = durationInMinutes * 60` 秒。`insulin == 0` 表示取消。
public final class CmdExtendedBolusSet: BaseSetting {

    public let insulin: Double
    public let durationInMinutes: Int
    public let cancel: Bool
    public let step: Int
    public let pumpTime: Int

    public init(insulin: Double, durationInMinutes: Int, cancel: Bool, settings: EquilSettingsStore) {
        self.insulin = insulin
        self.durationInMinutes = durationInMinutes
        self.cancel = cancel
        if insulin != 0.0 {
            self.step = Int(insulin / 0.05 * 8)
            self.pumpTime = durationInMinutes * 60
        } else {
            self.step = 0
            self.pumpTime = 0
        }
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
    }

    /// v39：跳过 CCC 写入——保持跳 CCC 客户端画像。
    public override var preferNoCccSubscription: Bool { true }

    public override func getFirstData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let zero = EquilBytes.intToBytes(0)
        let data = EquilBytes.concat(
            indexByte, [0x01, 0x03],
            zero, zero,
            EquilBytes.intToBytes(step),
            EquilBytes.intToBytes(pumpTime)
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
        cancel ? .cancelExtendedBolus : .setExtendedBolus
    }
}