import Foundation

/// AES 域命令基类，对照 AndroidAPS `manager/command/BaseCmd.kt`。
///
/// 负责链路层分帧（`responseCmd`）、收帧 CRC 校验与重发替换（`checkData`）、
/// 以及把收到的帧序列还原成 `EquilCmdModel`（`decodeModel`）。
///
/// Swift 无抽象类，抽象方法以 `fatalError` 占位，由子类覆写。
open class BaseCmd {

    public let createTime: Int64
    public let settings: EquilSettingsStore

    public var resolvedResult: ResolvedResult = .none
    public var timeOut: Int = 10000
    public var connectTimeOut: Int = 10000

    /// 命令完成信号。对照 AAPS 各命令收尾处的 `synchronized(this){ cmdStatus=true; notifyAll() }`：
    /// 泵应答被完整解析（或 fire-and-forget 发出）后 `markDone()`，执行层据此结束守护等待。
    public let completion = NSCondition()

    /// 端口号（4 位十六进制），各命令不同。
    public var port: String = "0404"
    public var config: Bool = false
    public var isEndFlag: Bool = false
    public var cmdStatus: Bool = false
    public var enacted: Bool = true
    public var response: EquilResponse?
    public var runPwd: String?
    public var runCode: String?

    public init(createTime: Int64, settings: EquilSettingsStore) {
        self.createTime = createTime
        self.settings = settings
    }

    /// 对照 `BaseCmd.DEFAULT_PORT`。
    public static let defaultPort = "0F0F"

    public var statusDescription: String { String(describing: type(of: self)) }

    /// 官方域/AES 域均需跳过 f001 的 CCC 描述符写入（泵据此区分客户端画像）。
    /// 子类按需覆写为 true。
    open var preferNoCccSubscription: Bool { false }

    /// 对照 `BaseCmd.isPairStep`：是否每次连接都要重新构建命令（官方域无会话继承）。
    open func isPairStep() -> Bool { false }

    /// 对照 `BaseCmd.isEnd`：命令是否已走到结束帧。
    public var isEnd: Bool { isEndFlag }

    // MARK: - 完成信号

    /// 标记命令完成并唤醒等待者。对照各命令的 `cmdStatus=true; notifyAll()`。
    public func markDone() {
        completion.lock()
        cmdStatus = true
        completion.broadcast()
        completion.unlock()
    }

    /// 守护等待：命令完成、已产生结果或超时后返回是否完成。
    /// 对照 `EquilManager.waitForCommand`（防 notify 早于 wait 的丢失通知竞态）。
    @discardableResult
    public func waitForCompletion(budgetMs: Int64) -> Bool {
        let deadline = Date().addingTimeInterval(Double(budgetMs) / 1000.0)
        completion.lock()
        defer { completion.unlock() }
        while !cmdStatus && resolvedResult == .none {
            if !completion.wait(until: deadline) { break }
        }
        return cmdStatus
    }

    // MARK: - 子类实现

    open func getEquilResponse() -> EquilResponse? { fatalError("abstract") }
    open func getNextEquilResponse() -> EquilResponse? { fatalError("abstract") }
    open func decodeEquilPacket(_ data: [UInt8]) -> EquilResponse? { fatalError("abstract") }
    open func decode() throws -> EquilResponse? { fatalError("abstract") }
    open func decodeConfirm() throws -> EquilResponse? { fatalError("abstract") }
    open func getEventType() -> EquilEventType? { fatalError("abstract") }

    // MARK: - 收帧校验

    /// 对照 `BaseCmd.checkData`。
    ///
    /// 1. crc8 校验失败 → 丢弃。
    /// 2. 若缓冲中已存在同 index 帧（泵重发），移除旧帧并接受新帧（v50 替换语义）。
    /// 3. `response` 未初始化（连接建立前的重连窗口）→ 丢弃而非抛异常（v41）。
    public func checkData(_ data: [UInt8]) -> Bool {
        guard let response = response else {
            return false
        }
        guard data.count >= 6 else { return false }
        let index = Int(data[3] & 0xFF)
        let crc = Int(data[5] & 0xFF)
        let crc1 = Int(EquilCRC.crc8Maxim(Array(data[0..<5])))
        if crc != crc1 {
            return false
        }
        if !response.send.isEmpty {
            if let pos = response.send.firstIndex(where: { Int($0[3] & 0xFF) == index }) {
                response.send.remove(at: pos)
                return true
            }
        }
        return true
    }

    // MARK: - 链路层分帧（AES 域）

    /// 对照 `BaseCmd.responseCmd`：把 `port + tag + iv + ciphertext` 切成链路层帧。
    ///
    /// 首帧载荷 = `allByte[0..3] + crc16(2) + allByte[4..7]`（共 10B）；
    /// 续帧每片 ≤10B；末帧 index 置结束位。
    public func responseCmd(_ model: EquilCmdModel, port: String) -> EquilResponse {
        let allHex = port + (model.tag ?? "") + (model.iv ?? "") + (model.ciphertext ?? "")
        let allByte = Hex.decode(allHex)
        let crc1 = EquilCRC.crc16(allByte)

        var byteIndex = 0
        var lastLen = 0
        let index = ((allByte.count - 8) % 10 == 0) ? 1 : 2
        let maxLen = ((allByte.count - 8) / 10) + index

        let equilResponse = EquilResponse(createTime: createTime)
        let msgIndex = UInt8(EquilCounters.reqIndex & 0xFF)

        for i in 0..<maxLen {
            var buffer: [UInt8] = []
            buffer.append(0x00)
            buffer.append(0x00)
            let isLast = (i == maxLen - 1)
            if isLast {
                buffer.append(UInt8(6 + lastLen))
                buffer.append(UInt8((10 * i) & 0xFF))
                buffer.append(EquilLinkFrame.settingEndBit(msgIndex))
            } else {
                buffer.append(0x10)
                buffer.append(UInt8((10 * i) & 0xFF))
                buffer.append(EquilLinkFrame.clearingEndBit(msgIndex))
            }
            buffer.append(EquilCRC.crc8Maxim(Array(buffer[0..<5])))

            if i == 0 {
                buffer.append(allByte[0])
                buffer.append(allByte[1])
                buffer.append(allByte[2])
                buffer.append(allByte[3])
                buffer.append(crc1[1])
                buffer.append(crc1[0])
                buffer.append(allByte[4])
                buffer.append(allByte[5])
                buffer.append(allByte[6])
                buffer.append(allByte[7])
                byteIndex = 8
            } else {
                let n = lastLen < 10 ? lastLen : 10
                for _ in 0..<n {
                    buffer.append(allByte[byteIndex])
                    byteIndex += 1
                }
            }
            lastLen = allByte.count - byteIndex
            equilResponse.add(buffer)
        }
        EquilCounters.reqIndex += 1
        return equilResponse
    }

    // MARK: - 收帧还原

    /// 对照 `BaseCmd.decodeModel`：按帧序号排序 + 连续性校验，还原 `EquilCmdModel`。
    ///
    /// 收帧（泵→App）首帧载荷 = 6B 头 + 4B 载荷，续帧每片 10B；
    /// 故首帧取末 4 字节、续帧取 [6..]，拼出 `tag(16) + iv(12) + ciphertext`。
    /// 收帧布局与发帧布局不同，不能与 `responseCmd` 做往返对拍。
    open func decodeModel() throws -> EquilCmdModel {
        guard let response = response else { throw EquilError.noResponse }
        let frames = response.send.sorted { ($0[3] & 0xFF) < ($1[3] & 0xFF) }

        var expected = 0
        for f in frames {
            let idx = Int(f[3] & 0xFF)
            if idx != expected {
                throw EquilError.incompleteFrameSequence(expected: expected, got: idx, buffered: frames.count)
            }
            expected += 10
        }

        var list: [UInt8] = []
        var model = EquilCmdModel()
        for (i, bs) in frames.enumerated() {
            if i == 0 {
                guard bs.count >= 12 else { throw EquilError.shortPayload(bs.count) }
                list.append(contentsOf: bs[(bs.count - 4)..<bs.count])
                model.code = Hex.encode([bs[10], bs[11]])
            } else {
                guard bs.count >= 6 else { throw EquilError.shortPayload(bs.count) }
                list.append(contentsOf: bs[6..<bs.count])
            }
        }
        guard list.count >= 28 else { throw EquilError.shortPayload(list.count) }

        let list1 = Array(list[0..<16])
        let list2 = Array(list[16..<28])
        let list3 = Array(list[28...])
        model.tag = Hex.encode(list1).lowercased()
        model.iv = Hex.encode(list2).lowercased()
        model.ciphertext = Hex.encode(list3).lowercased()
        return model
    }

    // MARK: - 工具

    /// 对照 `BaseCmd.convertString`：每个字符前补 "0"，把 ASCII 串转为 hex 串。
    /// 设为静态以便子类在 `super.init` 之前构造 `sn`。
    public static func convertString(_ input: String) -> String {
        var out = ""
        for ch in input {
            out += "0"
            out.append(ch)
        }
        return out
    }
}