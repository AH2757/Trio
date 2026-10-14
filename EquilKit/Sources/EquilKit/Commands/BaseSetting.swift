import Foundation

/// AES 域"设置类"命令基类，对照 AndroidAPS `manager/command/BaseSetting.kt`。
///
/// 生命周期（两阶段）：
/// 1. `getEquilResponse()`：用**会话密码**（`settings.equilPassword`）加密首帧数据，端口 `0F0F0000`。
/// 2. 泵应答 → `decodeEquilPacket` → `decode()`：解密取回新的会话密码 `runPwd` 与 `runCode`，
///    再用 `runPwd` 加密 `getFirstData()`，端口 `port + runCode`。
/// 3. 泵再应答 → `decodeConfirm()`：用 `runPwd` 解密确认段，`decodeConfirmData` 取数，
///    然后用 `runPwd` 加密 `getNextData()` 发出。
open class BaseSetting: BaseCmd {

    public override init(createTime: Int64, settings: EquilSettingsStore) {
        super.init(createTime: createTime, settings: settings)
    }

    /// 对照 `BaseSetting.getReqData`：`intToBytes(pumpReqIndex) + 设备标识字节`。
    public func getReqData() -> [UInt8] {
        let indexByte = EquilBytes.intToBytes(EquilCounters.pumpReqIndex)
        let devices = Hex.decode(settings.equilDevices)
        let data = EquilBytes.concat(indexByte, devices)
        EquilCounters.pumpReqIndex += 1
        return data
    }

    open override func getEquilResponse() -> EquilResponse? {
        config = false
        isEndFlag = false
        response = EquilResponse(createTime: createTime)
        let pwd = Hex.decode(settings.equilPassword)
        let data = getReqData()
        do {
            let model = try EquilAES.encrypt(key: pwd, data: data)
            return responseCmd(model, port: BaseCmd.defaultPort + "0000")
        } catch {
            cmdStatus = false
            return nil
        }
    }

    open override func decodeEquilPacket(_ data: [UInt8]) -> EquilResponse? {
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
                // v54：decode 失败不重置——保留已收帧等泵重发补齐。
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
            return nil
        }
    }

    open override func decode() throws -> EquilResponse? {
        let reqModel = try decodeModel()
        let pwd = Hex.decode(settings.equilPassword)
        let content = try EquilAES.decrypt(reqModel, key: pwd)
        let pwd2 = String(content.dropFirst(8))
        runPwd = pwd2
        let data = getFirstData()
        let model = try EquilAES.encrypt(key: Hex.decode(pwd2), data: data)
        runCode = reqModel.code
        return responseCmd(model, port: port + (runCode ?? ""))
    }

    open override func getNextEquilResponse() -> EquilResponse? {
        config = true
        isEndFlag = false
        response = EquilResponse(createTime: createTime)
        let data = getFirstData()
        do {
            guard let runPwd = runPwd else { return nil }
            let model = try EquilAES.encrypt(key: Hex.decode(runPwd), data: data)
            return responseCmd(model, port: port + (runCode ?? ""))
        } catch {
            cmdStatus = false
            return nil
        }
    }

    open override func decodeConfirm() throws -> EquilResponse? {
        let model = try decodeModel()
        runCode = model.code
        guard let runPwd = runPwd else { return nil }
        let content = try EquilAES.decrypt(model, key: Hex.decode(runPwd))
        decodeConfirmData(Hex.decode(content))
        let data = getNextData()
        let model2 = try EquilAES.encrypt(key: Hex.decode(runPwd), data: data)
        return responseCmd(model2, port: port + (runCode ?? ""))
    }

    // MARK: - 子类实现

    /// 第二阶段首帧数据。
    open func getFirstData() -> [UInt8] { fatalError("abstract") }
    /// 第三阶段数据。
    open func getNextData() -> [UInt8] { fatalError("abstract") }
    /// 解析确认段（已解密的明文字节）。
    open func decodeConfirmData(_ data: [UInt8]) { fatalError("abstract") }
}