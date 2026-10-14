import Foundation

/// 对照 `EquilResponse`：一次命令的收发缓冲与错误信息。
public final class EquilResponse {

    public let cmdCreateTime: Int64
    /// 待发送 / 已接收的帧序列。
    public var send: [[UInt8]] = []
    public var errorMessage: String?
    public var delay: Int64 = 20

    public init(createTime: Int64) {
        self.cmdCreateTime = createTime
    }

    public func add(_ frame: [UInt8]) {
        send.append(frame)
    }

    public var hasError: Bool { errorMessage != nil }

    public var shouldDelay: Bool { delay > 0 }
}

/// 对照 `EquilCmdModel`：AES 域一条消息的三段（GCM 密文 + 认证标签 + 随机 IV）与 code。
public struct EquilCmdModel {
    /// 对照 AAPS：由收帧 [10..11] 解析出的 2 字节，用作下一条命令的端口后缀。
    public var code: String?
    public var iv: String?
    public var tag: String?
    public var ciphertext: String?

    public init() {}
}

/// 命令解析/执行结果，对照 AAPS `ResolvedResult`。
///
/// `Equatable` 供 `EquilPumpError` 合成（其 `commandFailed` 携带本类型）。
public enum ResolvedResult: Equatable {
    case none
    case success
    /// 已连接但命令尚未完成（AAPS `FAILURE`）。
    case failure
    case connectError
    case timeout
    /// 命令让位/未找到（AAPS `NOT_FOUNT`）：使等待循环立即退出而不判失败。
    case notFound
    case error
}

/// 对照 AAPS `EquilHistoryRecord.EventType` 中协议层用到的子集。
public enum EquilEventType {
    case initializeEquil
    case unpairEquil
    case readDevices
    case setTime
    case setTemporaryBasal
    case cancelTemporaryBasal
    case setBolus
    case cancelBolus
    case suspendDelivery
    case resumeDelivery
    case setBasalProfile
    case changeInsulin
    case setExtendedBolus
    case cancelExtendedBolus
    case setAlarmMute
    case setAlarmTone
    case setAlarmToneAndShake
    case setAlarmShake
}

/// 协议层错误。
public enum EquilError: Error, Equatable {
    case badCipherModel
    case noResponse
    case shortPayload(Int)
    case incompleteFrameSequence(expected: Int, got: Int, buffered: Int)
    case cryptoFailed(String)
}