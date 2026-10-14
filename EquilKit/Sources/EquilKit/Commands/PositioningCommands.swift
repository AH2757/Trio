import Foundation

/// 推杆步进（定位循环用），对照 AndroidAPS `manager/command/CmdStepSet.kt`。
///
/// `sendConfig=false` 时不发第三阶段确认帧（`decodeConfirm` 返回 nil）——
/// 定位循环里"只发步进、不落确认"的形态。
public final class CmdStepSet: BaseSetting {

    /// 是否发送第三阶段确认帧。
    public let sendConfig: Bool
    public let step: Int

    public init(sendConfig: Bool, step: Int, settings: EquilSettingsStore) {
        self.sendConfig = sendConfig
        self.step = step
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
        // v44：定位循环快速超时——正常应答 0.4–0.65s，3s 余量 4.6 倍。
        timeOut = 3000
    }

    /// v38：跳过 CCC 写入——定位循环断开重连后必须保持同一客户端画像。
    public override var preferNoCccSubscription: Bool { true }

    public override func getFirstData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let data = EquilBytes.concat(indexByte, [0x01, 0x07], EquilBytes.intToBytes(step))
        EquilCounters.pumpReqIndex += 1
        return data
    }

    public override func getNextData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let data = EquilBytes.concat(indexByte, [0x00, 0x07, 0x01], EquilBytes.intToBytes(0))
        EquilCounters.pumpReqIndex += 1
        return data
    }

    public override func decodeConfirmData(_ data: [UInt8]) {
        markDone()
    }

    /// 对照 `CmdStepSet.decodeConfirm`：`sendConfig=false` 时不回发第三阶段帧。
    public override func decodeConfirm() throws -> EquilResponse? {
        let model = try decodeModel()
        runCode = model.code
        guard let runPwd = runPwd else { return nil }
        let content = try EquilAES.decrypt(model, key: Hex.decode(runPwd))
        decodeConfirmData(Hex.decode(content))
        guard sendConfig else { return nil }
        let data = getNextData()
        let model2 = try EquilAES.encrypt(key: Hex.decode(runPwd), data: data)
        return responseCmd(model2, port: port + (runCode ?? ""))
    }

    public override func getEventType() -> EquilEventType? { nil }
}

/// 接触阻力读取，对照 AndroidAPS `manager/command/CmdResistanceGet.kt`。
///
/// 定位循环里判断推杆是否已顶到活塞。`enacted = value >= threshold`：
/// 固件 1.x 世代用 300 阈值，其他世代用 500（对照 AAPS 实测：fw1.6 接触阻力 306–339、
/// 自由行进 175–182，500 阈值会致定位永不满足）。
/// 确认段解析后不回发第三阶段帧（`decodeConfirm` 返回 nil）。
public final class CmdResistanceGet: BaseSetting {

    /// 当前泵固件版本（形如 "1.6"），决定阈值世代。
    public let firmwareVersion: String?

    /// 接触阻力原始值。
    public private(set) var value = 0
    /// 本次判定所用阈值。
    public private(set) var threshold = 500

    public init(firmwareVersion: String?, settings: EquilSettingsStore) {
        self.firmwareVersion = firmwareVersion
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
        port = "1515"
        // v44：定位循环快速超时——正常应答 0.4–0.65s，3s 余量 4.6 倍。
        timeOut = 3000
    }

    /// v38：跳过 CCC 写入——定位循环断开重连后必须保持同一客户端画像。
    public override var preferNoCccSubscription: Bool { true }

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
        guard data.count > 7 else {
            markDone()
            return
        }
        value = EquilBytes.bytesToInt(data[7], data[6])
        threshold = (firmwareVersion?.hasPrefix("1.") ?? false) ? 300 : 500
        enacted = value >= threshold
        EquilLog.debug("CmdResistanceGet value=\(value) threshold=\(threshold) fw=\(firmwareVersion ?? "nil") enacted=\(enacted)")
        markDone()
    }

    /// 对照 `CmdResistanceGet.decodeConfirm`：解析后不回发第三阶段帧。
    public override func decodeConfirm() throws -> EquilResponse? {
        let model = try decodeModel()
        runCode = model.code
        guard let runPwd = runPwd else { return nil }
        let content = try EquilAES.decrypt(model, key: Hex.decode(runPwd))
        decodeConfirmData(Hex.decode(content))
        return nil
    }

    public override func getEventType() -> EquilEventType? { nil }
}