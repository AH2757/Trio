import Foundation

/// Equil 官方协议帧编解码（明文域），对照 AndroidAPS `official/OfficialFrame.kt`。
///
/// 与 AES 域共用同一链路层（见 `EquilLinkFrame`）。官方域用于设备查询、
/// 时间同步、状态/基础率读取等；治疗类命令走 AES 域。
///
/// 首帧载荷 = 8B 头 + 前 2B 数据；续帧每片 ≤10B。
public enum OfficialFrame {

    public static let opAck = 0x00     // App→泵: 确认泵的 op5 通知
    public static let opWrite = 0x01   // App→泵: 写入/设置
    public static let opRead = 0x02    // App→泵: 查询
    public static let opNotify = 0x05  // 泵→App: 通知/应答数据
    public static let opDone = 0x06    // 泵→App: 写命令完成确认

    public static let portDevice = 0x00   // 设备级（查询）
    public static let portConfig = 0x04   // 配置/输注控制
    public static let portTherapy = 0x05  // 时间/基础率/状态

    /// 会话内消息令牌：随机 16 位（泵仅回显不校验内容）。
    public static func nextToken() -> Int {
        Int.random(in: 0..<0x10000)
    }

    /// 构造一条完整消息（自动分帧）。
    /// - Parameter ackToken: 0 = 新请求；应答/ACK 时回显对方消息的 token。
    public static func build(
        createTime: Int64,
        srcPort: Int,
        dstPort: Int,
        operation: Int,
        parameter: Int,
        data: [UInt8],
        ackToken: Int,
        token: Int,
        msgIndex: Int
    ) -> EquilResponse {
        let header: [UInt8] = [
            UInt8(srcPort & 0xFF), UInt8(dstPort & 0xFF),
            UInt8((ackToken >> 8) & 0xFF), UInt8(ackToken & 0xFF),
            UInt8((token >> 8) & 0xFF), UInt8(token & 0xFF),
            UInt8(operation & 0xFF), UInt8(parameter & 0xFF)
        ]
        let firstPayload = header + Array(data.prefix(2))
        let rest = data.count > 2 ? Array(data[2...]) : []

        var frames: [[UInt8]] = [firstPayload]
        var offset = 0
        while offset < rest.count {
            let end = min(offset + 10, rest.count)
            frames.append(Array(rest[offset..<end]))
            offset = end
        }

        let response = EquilResponse(createTime: createTime)
        let total = frames.count
        for (i, payload) in frames.enumerated() {
            let flags = i == 0 ? 0x00 : 0x0A * i
            let endBit = i == total - 1 ? 0x80 : 0x00
            let indexByte = UInt8((msgIndex | endBit) & 0xFF)
            let frame = EquilLinkFrame.makeFrame(
                flags: UInt8(flags & 0xFF),
                indexByte: indexByte,
                payload: payload
            )
            response.add(frame)
        }
        return response
    }

    /// 解析后的泵→App 完整消息。
    public struct Message {
        public let srcPort: Int
        public let dstPort: Int
        public let ackToken: Int   // 回显的我方 token
        public let token: Int      // 泵侧令牌（ACK 时需回显）
        public let operation: Int
        public let parameter: Int
        public let data: [UInt8]
    }

    /// 校验单帧链路层完整性。false = CRC 错误/长度异常，应丢弃。
    public static func validateLinkLayer(_ frame: [UInt8]) -> Bool {
        EquilLinkFrame.validate(frame)
    }
}