import Foundation

/// 泵绑定命令，对照 AndroidAPS `manager/command/CmdPair.kt`。
///
/// 三步握手：用 `SHA256(sn)` 作密钥发握手材料 → 解密取回 `pwd1/pwd2`（写入设备标识与会话密码）
/// → 用 `pwd2` 加密确认段发出。绑定后泵进入受控状态。
public final class CmdPair: BaseCmd {

    /// 对照 `CmdPair.ERROR_PWD`。
    public static let errorPwd = String(repeating: "0", count: 64)

    public var address: String
    private let password: String
    private let sn: String
    public var randomPassword: [UInt8]?

    /// 原始广播名（`Equil - <SN>`）。iOS 无 MAC，连接时用名字前缀匹配设备。
    public let deviceName: String

    public init(name: String, address: String, password: String, settings: EquilSettingsStore) {
        self.address = address
        self.password = password
        self.deviceName = name
        let trimmed = name.replacingOccurrences(of: "Equil - ", with: "").trimmingCharacters(in: .whitespaces)
        // sn = 每个 ASCII 字符前补 "0" 得到的 hex 串（对照 BaseCmd.convertString）
        self.sn = BaseCmd.convertString(trimmed)
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
        self.port = "0E0E"
        self.timeOut = 5000
        self.connectTimeOut = 6000
    }

    public override var preferNoCccSubscription: Bool { true }

    public override func getEquilResponse() -> EquilResponse? {
        response = EquilResponse(createTime: createTime)
        let snBytes = Hex.decode(sn)
        let pwd = EquilAES.sha256(snBytes)
        let equilPassword = EquilAES.equilPassword(password)
        let random = EquilBytes.randomBytes(32)
        randomPassword = random
        let data = equilPassword + random
        do {
            let model = try EquilAES.encrypt(key: pwd, data: data)
            return responseCmd(model, port: "0D0D0000")
        } catch {
            return nil
        }
    }

    public override func getNextEquilResponse() -> EquilResponse? {
        getEquilResponse()
    }

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

    public override func decode() throws -> EquilResponse? {
        let model = try decodeModel()
        guard let keyBytes = randomPassword else { return nil }
        let content = try EquilAES.decrypt(model, key: keyBytes)
        let pwd1 = String(content.prefix(64))
        let pwd2 = String(content.dropFirst(64))

        if pwd1 == CmdPair.errorPwd && pwd2 == CmdPair.errorPwd {
            markDone()
            enacted = false
            return nil
        }

        settings.equilPassword = pwd2
        settings.equilDevices = pwd1
        runPwd = pwd2
        let data = Hex.decode(pwd1) + keyBytes
        let model2 = try EquilAES.encrypt(key: Hex.decode(pwd2), data: data)
        runCode = model.code
        return responseCmd(model2, port: port + (runCode ?? ""))
    }

    public override func decodeConfirm() throws -> EquilResponse? {
        markDone()
        return nil
    }

    public override func getEventType() -> EquilEventType? { .initializeEquil }
}

/// 泵解绑命令，对照 AndroidAPS `manager/command/CmdUnPair.kt`。
///
/// 三步握手与 CmdPair 相同，但确认段为 32 字节全 0，通知泵清除绑定、恢复可配对状态。
/// 需要用户**原始配对密码**。
public final class CmdUnPair: BaseCmd {

    private let sn: String
    public var randomPassword: [UInt8]?
    public let password: String
    /// 原始广播名（`Equil - <SN>`），iOS 侧连接匹配用。
    public let deviceName: String
    /// auto-unpair 竞态消解：来源标记（自动解绑/手动解绑不让位）。
    public var fromAutoUnpair: Bool = false
    /// 在请求写出前让位（队列有命令时）——泵保持绑定，排队命令复用连接。
    public var yieldedToQueue: Bool = false

    public init(name: String, password: String, settings: EquilSettingsStore) {
        self.password = password
        self.deviceName = name
        let trimmed = name.replacingOccurrences(of: "Equil - ", with: "").trimmingCharacters(in: .whitespaces)
        self.sn = BaseCmd.convertString(trimmed)
        super.init(createTime: Int64(Date().timeIntervalSince1970 * 1000), settings: settings)
        self.port = "0E0E"
    }

    public override var preferNoCccSubscription: Bool { true }

    private func clear1() -> EquilResponse? {
        let snBytes = Hex.decode(sn)
        let pwd = EquilAES.sha256(snBytes)
        let equilPassword = EquilAES.equilPassword(password)
        let random = EquilBytes.randomBytes(32)
        randomPassword = random
        let data = equilPassword + random
        do {
            let model = try EquilAES.encrypt(key: pwd, data: data)
            return responseCmd(model, port: "0D0D0000")
        } catch {
            return nil
        }
    }

    public override func getEquilResponse() -> EquilResponse? {
        response = EquilResponse(createTime: createTime)
        return clear1()
    }

    public override func getNextEquilResponse() -> EquilResponse? {
        getEquilResponse()
    }

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

    public override func decode() throws -> EquilResponse? {
        let model = try decodeModel()
        guard let keyBytes = randomPassword else { return nil }
        // 确认段 32 字节全 0：清除泵端绑定指令
        let zero32 = [UInt8](repeating: 0x00, count: 32)
        let content = try EquilAES.decrypt(model, key: keyBytes)
        let pwd1 = String(content.prefix(64))
        let pwd2 = String(content.dropFirst(64))
        runPwd = pwd2
        let data = Hex.decode(pwd1) + zero32
        let model2 = try EquilAES.encrypt(key: Hex.decode(pwd2), data: data)
        runCode = model.code
        return responseCmd(model2, port: port + (runCode ?? ""))
    }

    public override func decodeConfirm() throws -> EquilResponse? {
        markDone()
        return nil
    }

    public override func getEventType() -> EquilEventType? { .unpairEquil }
}