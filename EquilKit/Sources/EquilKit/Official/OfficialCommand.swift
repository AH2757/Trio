import Foundation

/// 官方域命令基类，对照 AndroidAPS `official/OfficialCommand.kt`。
///
/// 与 AES 域共用链路层与命令执行框架，但画像不同：写入用 `withResponse`，
/// 且不写 f001 的 CCC 描述符（官方 SDK 全程不写，泵据此区分客户端类型）。
///
/// 生命周期：
/// 1. `getEquilResponse()` 构造官方帧（`isPairStep()=true` → 每次 ready 全新构建，无 AES 会话继承）。
/// 2. `decodeEquilPacket()` 收泵帧：链路层校验 → 分帧拼装 → 完整消息回调。
///    - op5(通知)：自动生成 op0 ACK 回发；子类 `onResponse(_:)` 取数。
///    - op6(完成)：写命令结束。
/// 3. `markDone()` → `cmdStatus=true`，执行层守护等待返回。
open class OfficialCommand: BaseCmd, EquilOfficialCommand {

    // MARK: - 子类描述

    open var srcPort: Int { fatalError("abstract") }
    open var dstPort: Int { fatalError("abstract") }
    open var operation: Int { fatalError("abstract") }
    open var parameter: Int { fatalError("abstract") }

    /// 命令数据（首帧带 ≤2B，超出自动分续帧）。
    open var commandData: [UInt8] { [] }

    /// op5 通知到达即视为命令完成（查询类）；写命令靠 op6。
    open var completesByNotify: Bool { false }

    /// 匹配的应答 param（默认与请求相同；部分查询应答 param 不同时覆写）。
    open var responseParam: Int { parameter }

    /// 覆写本命令固定 token（如设备查询 0x71E5，官方四日志字节级一致）；nil=随机生成。
    open var fixedToken: Int? { nil }

    /// 覆写本命令 ack 字段（新会话语义：官方激活/TBR 等独立流程命令 ack=0000，不回显泵 token）；
    /// nil=确认链回显泵 token。
    open var fixedAckToken: Int? { nil }

    /// 覆写消息索引（流程起始命令 idx=00，与 `fixedAckToken=0` 配套）；nil=全局递增计数器。
    open var fixedIndex: Int? { nil }

    /// 发出即完成（官方 SDK 异步模式：配置类命令不等泵 op6 应答）。
    open var fireAndForget: Bool { false }

    /// 是否对泵 op5 通知回发 op0 ACK。
    open var acksNotify: Bool { true }

    /// 是否对泵 op6 完成应答回发 op0 ACK（官方仅推杆步进 param7 回）。
    open var acksDone: Bool { false }

    // MARK: - 收帧状态

    private var msgToken = 0
    private var rxSrcPort = 0
    private var rxDstPort = 0
    private var rxAckToken = 0
    private var rxToken = 0
    private var rxOp = 0
    private var rxParam = -1
    private var rxData: [UInt8] = []

    public override init(createTime: Int64, settings: EquilSettingsStore) {
        super.init(createTime: createTime, settings: settings)
        // 泵应答实测 <300ms，4s 足够；静默时单命令最多损失 4s（快速失败）。
        timeOut = 4000
        // 首条命令需覆盖 bond 超时(12s) + GATT 建连(~3s) + 余量。
        connectTimeOut = 20000
    }

    /// 官方域无会话概念，每条命令全新构建。
    public final override func isPairStep() -> Bool { true }

    /// 官方域连接画像：不写 f001 CCC 描述符。
    public final override var preferNoCccSubscription: Bool { true }

    // MARK: - 发帧

    public final override func getEquilResponse() -> EquilResponse? {
        resetRxState()
        msgToken = fixedToken ?? OfficialFrame.nextToken()
        let ackToken = fixedAckToken ?? EquilOfficialSession.lastPumpToken
        // 流程起始命令 idx 固定且消耗该槽位（官方同步流 basal idx00 → 下一命令 idx01）。
        let msgIdx: Int
        if let fixed = fixedIndex {
            EquilCounters.reqIndex = (fixed + 1) & 0x7F
            msgIdx = fixed
        } else {
            msgIdx = nextMsgIndex()
        }
        EquilLog.debug("OfficialCmd \(type(of: self)): op=\(operation) param=\(parameter) port=\(srcPort)/\(dstPort) ack=\(hex16(ackToken)) idx=\(hex8(msgIdx)) token=\(hex16(msgToken)) data=\(Hex.encode(commandData))")
        let response = OfficialFrame.build(
            createTime: createTime,
            srcPort: srcPort,
            dstPort: dstPort,
            operation: operation,
            parameter: parameter,
            data: commandData,
            ackToken: ackToken,
            token: msgToken,
            msgIndex: msgIdx
        )
        if fireAndForget {
            // 帧已构建仍会写入泵，命令立即完成不等 op6。
            EquilLog.debug("OfficialCmd \(type(of: self)): fire-and-forget, not waiting for pump ack")
            markDone()
        }
        return response
    }

    public final override func getNextEquilResponse() -> EquilResponse? { getEquilResponse() }

    // MARK: - 收帧

    public final override func decodeEquilPacket(_ data: [UInt8]) -> EquilResponse? {
        guard OfficialFrame.validateLinkLayer(data) else {
            EquilLog.debug("OfficialCmd: link layer CRC fail, drop \(Hex.encode(data))")
            return nil
        }
        let payload = Array(data[6...])
        if EquilLinkFrame.isFirstFrame(data) {
            resetRxState()
            if payload.count < 8 { return nil }
            rxSrcPort = Int(payload[0])
            rxDstPort = Int(payload[1])
            rxAckToken = (Int(payload[2]) << 8) | Int(payload[3])
            rxToken = (Int(payload[4]) << 8) | Int(payload[5])
            rxOp = Int(payload[6])
            rxParam = Int(payload[7])
            rxData.append(contentsOf: payload[8...])
        } else {
            rxData.append(contentsOf: payload)
        }
        if !EquilLinkFrame.isEndFrame(data) { return nil }

        // 完整消息到达。
        let complete = OfficialFrame.Message(
            srcPort: rxSrcPort, dstPort: rxDstPort, ackToken: rxAckToken,
            token: rxToken, operation: rxOp, parameter: rxParam, data: rxData
        )
        // 确认链游标：泵本条消息 token 即下一条命令 [8..9] 须回显的值。
        EquilOfficialSession.lastPumpToken = complete.token
        EquilLog.debug("OfficialCmd \(type(of: self)) rx: op=\(complete.operation) param=\(complete.parameter) ackEcho=\(hex16(complete.ackToken)) token=\(hex16(complete.token)) data=\(Hex.encode(complete.data))")
        resetRxState()

        var ackToSend: EquilResponse?
        // token 回显校验：泵对本命令的应答 [8..9] 回显我方请求 token；
        // 不匹配 = 迟到帧/其他命令的应答 → 忽略（不 ACK、不 markDone），防 fire-and-forget 迟到 op6 串台。
        let forMe = complete.ackToken == msgToken
        switch complete.operation {
        case OfficialFrame.opNotify:
            if forMe && acksNotify {
                // 对泵通知回 op0 ACK（回显泵 token）；[4] 须置 bit6 类型标志（官方 ACK 恒 0xCx）。
                ackToSend = OfficialFrame.build(
                    createTime: createTime,
                    srcPort: srcPort, dstPort: dstPort,
                    operation: OfficialFrame.opAck, parameter: complete.parameter,
                    data: [0x01], ackToken: complete.token, token: OfficialFrame.nextToken(),
                    msgIndex: nextMsgIndex() | 0x40
                )
            }
            if forMe && complete.parameter == responseParam {
                onResponse(complete.data)
                if completesByNotify { markDone() }
            } else {
                onUnsolicited(complete)
            }
        case OfficialFrame.opDone:
            if forMe && complete.parameter == responseParam {
                onDoneAck(complete.data)
                markDone()
                if acksDone {
                    // 官方推杆步进完成 ACK 形态：op0/param7 data=01、idx=next|0x40。
                    ackToSend = OfficialFrame.build(
                        createTime: createTime,
                        srcPort: srcPort, dstPort: dstPort,
                        operation: OfficialFrame.opAck, parameter: complete.parameter,
                        data: [0x01], ackToken: complete.token, token: OfficialFrame.nextToken(),
                        msgIndex: nextMsgIndex() | 0x40
                    )
                }
            }
        default:
            break
        }
        return ackToSend
    }

    // MARK: - 子类钩子

    /// op5 数据到达（仅匹配 `responseParam` 的通知）。
    open func onResponse(_ data: [UInt8]) {}
    /// op6 写完成。
    open func onDoneAck(_ data: [UInt8]) {}
    /// 非本命令 param 的通知（如异步状态上报），默认忽略。
    open func onUnsolicited(_ msg: OfficialFrame.Message) {}

    // MARK: - 内部

    private func resetRxState() {
        rxData.removeAll()
        rxOp = 0
        rxParam = -1
    }

    /// 复用 AES 域全局消息计数器（同一链路层机制，泵不校验编号规律）。
    private func nextMsgIndex() -> Int {
        let idx = EquilCounters.reqIndex
        EquilCounters.reqIndex = (EquilCounters.reqIndex + 1) & 0x7F
        return idx
    }

    // BaseCmd AES 域抽象，官方命令不使用。
    public final override func decode() throws -> EquilResponse? { nil }
    public final override func decodeConfirm() throws -> EquilResponse? { nil }
    public final override func getEventType() -> EquilEventType? { nil }
}

/// 2 位大写十六进制。
private func hex8(_ value: Int) -> String { String(format: "%02X", UInt32(value & 0xFF)) }
/// 4 位大写十六进制。
private func hex16(_ value: Int) -> String { String(format: "%04X", UInt32(value & 0xFFFF)) }