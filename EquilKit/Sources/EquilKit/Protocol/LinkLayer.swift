import Foundation

/// 链路层校验。
///
/// 对照 AndroidAPS `manager/Crc.kt`。`crc8Maxim` 已在 8 个实测官方帧样本上
/// 交叉验证通过（见 `tools/verify_protocol.py`），可直接用于线上收帧校验。
public enum EquilCRC {

    /// 对照 `Crc.crc8Maxim`：poly 0x8C，初值 0x00，逐位右移。
    /// 由于每轮 `(crc >> 1) ^ 0x8C` 恒落在低 8 位，实现可用 UInt8，无需额外掩码。
    public static func crc8Maxim(_ data: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0x00
        let poly: UInt8 = 0x8C
        for b in data {
            crc ^= b
            for _ in 0..<8 {
                if crc & 0x01 != 0 {
                    crc = (crc >> 1) ^ poly
                } else {
                    crc >>= 1
                }
            }
        }
        return crc
    }

    /// 对照 `Crc.getCRC`：反射 CRC16，poly 0xA001，初值 0xFFFF，
    /// 返回 2 字节**大端**（等价 AAPS `hexStringToBytes(toHexString(crc))`）。
    /// 因每轮结果恒落在低 16 位，用 UInt32 实现与 AAPS 的 Int 算术右移等价。
    public static func crc16(_ data: [UInt8]) -> [UInt8] {
        var crc: UInt32 = 0x0000_FFFF
        let poly: UInt32 = 0x0000_A001
        for b in data {
            crc ^= UInt32(b)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ poly
                } else {
                    crc >>= 1
                }
            }
        }
        return [UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
    }
}

/// 链路层帧结构（官方域与 AES 域同构）。
///
/// ```
/// [0..1] addr   恒 00 00
/// [2]    len    帧总长度
/// [3]    flags  0x00 首帧；0x0A * n 第 n 续帧
/// [4]    index  消息编号（末帧置 0x80 结束位）
/// [5]    crc8   crc8Maxim([0..5))
/// [6..]  payload
/// ```
public enum EquilLinkFrame {

    public static let headerSize = 6

    /// 单帧链路层完整性：长度字段自洽 + crc8 匹配。失败应丢弃该帧。
    public static func validate(_ frame: [UInt8]) -> Bool {
        guard frame.count >= 8, frame.count == Int(frame[2]) else { return false }
        return frame[5] == EquilCRC.crc8Maxim(Array(frame[0..<5]))
    }

    public static func isFirstFrame(_ frame: [UInt8]) -> Bool {
        frame.count > 3 && frame[3] == 0x00
    }

    public static func isEndFrame(_ frame: [UInt8]) -> Bool {
        frame.count > 4 && (frame[4] & 0x80) != 0
    }

    /// 对照 `BaseCmd.getIndex`：取 index 低 6 位。
    public static func messageIndex(_ frame: [UInt8]) -> Int {
        Int(frame[4] & 0x3F)
    }

    /// 对照 `BaseCmd.isEnd`：index 第 7 位为结束标志。
    public static func isEndByte(_ b: UInt8) -> Bool {
        ((b >> 7) & 0x01) == 1
    }

    /// 对照 `BaseCmd.toNewStart`：清除结束位。
    public static func clearingEndBit(_ b: UInt8) -> UInt8 { b & 0x7F }

    /// 对照 `BaseCmd.toNewEndConf`：置结束位。
    public static func settingEndBit(_ b: UInt8) -> UInt8 { b | 0x80 }

    /// 组装一帧（addr 固定 00 00，[5] 自动计算 crc8）。供链路层构造使用。
    public static func makeFrame(flags: UInt8, indexByte: UInt8, payload: [UInt8]) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: headerSize + payload.count)
        frame[0] = 0x00
        frame[1] = 0x00
        frame[2] = UInt8(frame.count)
        frame[3] = flags
        frame[4] = indexByte
        frame[5] = EquilCRC.crc8Maxim(Array(frame[0..<5]))
        frame.replaceSubrange(headerSize..<frame.count, with: payload)
        return frame
    }
}