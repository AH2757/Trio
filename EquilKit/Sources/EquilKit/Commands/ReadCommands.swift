import Foundation

/// 读取设备信息，对照 AndroidAPS `manager/command/CmdDevicesGet.kt`。
///
/// 解出绑定状态疑似字段与固件版本（`data[18].data[19]`）。
public final class CmdDevicesGet: BaseSetting {

    /// 疑似设备数/绑定状态（AAPS 注释：`data[6][7]`）。
    public private(set) var suspectedBindOrCount: Int = 0
    /// 固件版本，形如 "1.2"。
    public private(set) var firmwareVersion: String = ""
    /// 原始确认段，供后续解析未定义区段（`data[8..17]`）。
    public private(set) var rawConfirm: [UInt8] = []

    public init(settings: EquilSettingsStore) {
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
        port = "0000"
    }

    public override var preferNoCccSubscription: Bool { true }

    public override func getFirstData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let data = EquilBytes.concat(indexByte, [0x02, 0x00])
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
        rawConfirm = data
        guard data.count >= 20 else {
            markDone()
            return
        }
        suspectedBindOrCount = EquilBytes.bytesToInt(data[7], data[6])
        let major = Int(Int8(bitPattern: data[18]))
        let minor = Int(Int8(bitPattern: data[19]))
        firmwareVersion = "\(major).\(minor)"
        markDone()
    }

    public override func getEventType() -> EquilEventType? { .readDevices }
}

/// 读取运行模式，对照 AndroidAPS `manager/command/CmdModelGet.kt`。
public final class CmdModelGet: BaseSetting {

    /// 运行模式原始值（0 暂停 / 1 运行 / 2 停止）。
    public private(set) var mode: Int = 0

    public init(settings: EquilSettingsStore) {
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
        timeOut = 4000
    }

    public override var preferNoCccSubscription: Bool { true }

    public override func getFirstData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let data = EquilBytes.concat(indexByte, [0x02, 0x00])
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
        guard data.count > 6 else { return }
        mode = Int(data[6] & 0xFF)
        markDone()
    }

    public override func getEventType() -> EquilEventType? { nil }
}

/// 读取剩余药量，对照 AndroidAPS `manager/command/CmdInsulinGet.kt`。
public final class CmdInsulinGet: BaseSetting {

    /// 剩余药量（U）。
    public private(set) var insulin: Int = 0

    public init(settings: EquilSettingsStore) {
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
        port = "0505"
    }

    public override var preferNoCccSubscription: Bool { true }

    public override func getFirstData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let data = EquilBytes.concat(indexByte, [0x02, 0x07])
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
        guard data.count > 6 else { return }
        insulin = Int(data[6] & 0xFF)
        markDone()
    }

    public override func getEventType() -> EquilEventType? { nil }
}

/// 读取当前 TBR，对照 AndroidAPS `manager/command/CmdTempBasalGet.kt`。
public final class CmdTempBasalGet: BaseSetting {

    /// TBR 步进值（原始）。
    public private(set) var step: Int = 0
    /// TBR 剩余时间（分钟）。
    public private(set) var time: Int = 0

    public init(settings: EquilSettingsStore) {
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
        timeOut = 4000
    }

    public override var preferNoCccSubscription: Bool { true }

    public override func getFirstData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let data = EquilBytes.concat(indexByte, [0x02, 0x04])
        EquilCounters.pumpReqIndex += 1
        return data
    }

    public override func getNextData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let data = EquilBytes.concat(indexByte, [0x00, 0x04, 0x02], EquilBytes.intToBytes(0))
        EquilCounters.pumpReqIndex += 1
        return data
    }

    public override func decodeConfirmData(_ data: [UInt8]) {
        guard data.count > 13 else { return }
        step = EquilBytes.bytes2Int(Array(data[6...9]))
        time = EquilBytes.bytes2Int(Array(data[10...13]))
        markDone()
    }

    public override func getEventType() -> EquilEventType? { nil }
}

/// 旧版设备查询，对照 AndroidAPS `manager/command/CmdDevicesOldGet.kt`。
///
/// 与新协议（`CmdDevicesGet`）不同：首帧是**硬编码明文帧**（不走 AES），
/// 收帧还原只取密文段（无 tag/iv），固件版本从密文 `[12].[13]` 读取。
/// 主要用于解绑前的设备探测与调试界面。
public final class CmdDevicesOldGet: BaseSetting {

    /// 固件版本（数值，供 `isSupport` 比较）。
    public private(set) var firmwareVersion: Float = 0
    /// 固件版本（字符串，形如 "1.6"）。
    public private(set) var firmwareVersionString: String = ""
    /// 疑似设备数/绑定状态（`data[6][7]`）。
    public private(set) var suspectedBindOrCount: Int = 0

    public init(settings: EquilSettingsStore) {
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
        port = "0E0E"
        connectTimeOut = 6000
    }

    /// 对照 `CmdDevicesOldGet.getEquilResponse`：硬编码 14 字节明文帧，不加密。
    /// `[2]=0x0E` 长度、`[3]=0x00` 首帧、`[4]=0x80` 末帧、`[5]=0x78` crc8。
    public override func getEquilResponse() -> EquilResponse? {
        config = false
        isEndFlag = false
        response = EquilResponse(createTime: createTime)
        let temp = EquilResponse(createTime: createTime)
        temp.add([0x00, 0x00, 0x0E, 0x00, 0x80, 0x78, 0x00, 0x00, 0x00, 0x00, 0x01, 0x7B, 0x02, 0x00])
        return temp
    }

    public override func getFirstData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let data = EquilBytes.concat(indexByte, [0x02, 0x00])
        EquilCounters.pumpReqIndex += 1
        return data
    }

    public override func getNextData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let data = EquilBytes.concat(indexByte, [0x00, 0x00, 0x01])
        EquilCounters.pumpReqIndex += 1
        return data
    }

    /// 对照 `CmdDevicesOldGet.decodeEquilPacket`：与 BaseSetting 同构，
    /// 但失败分支会重置收帧缓冲（非 v54 的"保留等重发"语义）。
    public override func decodeEquilPacket(_ data: [UInt8]) -> EquilResponse? {
        guard checkData(data) else { return nil }
        let code = data[4]
        let intValue = EquilLinkFrame.messageIndex(data)

        if config {
            if EquilCounters.rspIndex == intValue { return nil }
            let flag = EquilLinkFrame.isEndByte(code)
            response?.add(data)
            if !flag { return nil }
            do {
                let result = try decodeConfirm()
                isEndFlag = true
                response = EquilResponse(createTime: createTime)
                EquilCounters.rspIndex = intValue
                return result
            } catch {
                response = EquilResponse(createTime: createTime)
                return nil
            }
        }

        let flag = EquilLinkFrame.isEndByte(code)
        response?.add(data)
        if !flag { return nil }
        do {
            let result = try decode()
            response = EquilResponse(createTime: createTime)
            config = true
            EquilCounters.rspIndex = intValue
            return result
        } catch {
            response = EquilResponse(createTime: createTime)
            return nil
        }
    }

    /// 对照 `CmdDevicesOldGet.decode`：密文段直接就是明文设备信息，不 AES 解密。
    public override func decode() throws -> EquilResponse? {
        var model = try decodeModel()
        guard let cipherHex = model.ciphertext else { throw EquilError.badCipherModel }
        let data = Hex.decode(cipherHex)
        if data.count > 13 {
            let fv = "\(Int8(bitPattern: data[12])).\(Int8(bitPattern: data[13]))"
            firmwareVersion = Float(fv) ?? 0
            firmwareVersionString = fv
        }
        EquilLog.debug("CmdDevicesOldGet data=\(Hex.encode(data)) fw=\(firmwareVersionString)")
        model.ciphertext = Hex.encode(getNextData())
        markDone()
        return responseCmd(model, port: "0000" + (model.code ?? ""))
    }

    /// 对照 `CmdDevicesOldGet.decodeModel`：只拼密文（无 tag/iv），首帧取末 2 字节。
    public override func decodeModel() throws -> EquilCmdModel {
        guard let response = response else { throw EquilError.noResponse }
        var model = EquilCmdModel()
        var list: [UInt8] = []
        for (i, bs) in response.send.enumerated() {
            if i == 0 {
                guard bs.count >= 12 else { throw EquilError.shortPayload(bs.count) }
                model.code = Hex.encode([bs[10], bs[11]])
                list.append(bs[bs.count - 2])
                list.append(bs[bs.count - 1])
            } else {
                guard bs.count >= 6 else { throw EquilError.shortPayload(bs.count) }
                list.append(contentsOf: bs[6..<bs.count])
            }
        }
        model.ciphertext = Hex.encode(list).lowercased()
        model.tag = ""
        model.iv = ""
        return model
    }

    public override func decodeConfirmData(_ data: [UInt8]) {
        if data.count > 7 {
            suspectedBindOrCount = EquilBytes.bytesToInt(data[7], data[6])
        }
        if data.count > 19 {
            let fv = "\(Int8(bitPattern: data[18])).\(Int8(bitPattern: data[19]))"
            firmwareVersion = Float(fv) ?? 0
            firmwareVersionString = fv
        }
        EquilLog.debug("CmdDevicesOldGet confirm data=\(Hex.encode(data)) fw=\(firmwareVersionString)")
        markDone()
    }

    public func isSupport() -> Bool { firmwareVersion >= EquilConst.supportLevel }

    public override func getEventType() -> EquilEventType? { nil }
}