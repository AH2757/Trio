import Foundation

/// 官方域命令标记协议。
///
/// 官方域与 AES 域共用链路层，但在写入类型（withResponse）与 CCC 画像上不同。
/// 链路层用本协议做 `is` 判定，避免对具体命令类型硬编码。
/// `OfficialCommand` 及子类实现此协议。
public protocol EquilOfficialCommand: AnyObject {
    /// 目标端口（0x00 设备级 / 0x04 配置 / 0x05 治疗）。0x00 时保留本地通知订阅。
    var dstPort: Int { get }
}

/// 官方域会话游标（进程级）。
///
/// 对照 AAPS `OfficialCommand.companion`：泵最近一次通知的 token，是下一条命令
/// 必须回显的 ack 值——滑动确认协议。仅单连接内有效，断连即清零。
public enum EquilOfficialSession {

    /// 泵最近一次通知的 token。
    public static var lastPumpToken: Int = 0

    /// 新流程开始：消息索引计数器归零（官方每流程从 00 重新计数）。
    public static func resetFlow() {
        EquilCounters.reqIndex = 0
    }
}