import Foundation
import LoopKit
import EquilKit

/// 驱动层错误，对照 MedtrumKit 的 `MedtrumConnectError`。
///
/// 通过 `PumpManagerError.deviceState(_)` 抛出，向 LoopKit 表明是"设备状态"类失败
/// （区别于通信失败 `.communication`）。
public enum EquilPumpError: Error, LocalizedError, Equatable {

    /// 尚未完成向导。
    case notOnboarded
    /// 泵未初始化（换药未完成/未设置运行模式）。
    case pumpNotInitialized
    /// 缺少泵号/密码。
    case missingPairingInfo
    /// 泵处于停止或暂停，不能下发剂量。
    case notRunning
    /// 已有大剂量在进行。
    case isBolussing
    /// 命令执行失败（携带链路层结果）。
    case commandFailed(ResolvedResult)
    /// 命令等待超时。
    case commandTimeout
    /// 连接失败（扫描不到、连不上）。
    case connectionFailed
    /// 不支持的参数。
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .notOnboarded: return "Equil 泵尚未完成配置"
        case .pumpNotInitialized: return "Equil 泵尚未初始化，请先完成更换储药器流程"
        case .missingPairingInfo: return "缺少泵号或配对密码"
        case .notRunning: return "Equil 泵未处于运行状态"
        case .isBolussing: return "Equil 泵正在输注大剂量"
        case .commandFailed(let result): return "Equil 命令失败：\(result)"
        case .commandTimeout: return "Equil 命令等待超时"
        case .connectionFailed: return "无法连接 Equil 泵"
        case .unsupported(let detail): return "不支持的操作：\(detail)"
        }
    }

    /// 包成 LoopKit 的设备状态错误。
    public var asPumpManagerError: PumpManagerError { .deviceState(self) }
}