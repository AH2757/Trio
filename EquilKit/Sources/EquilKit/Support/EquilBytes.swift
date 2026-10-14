import Foundation

/// 十六进制与字节序工具。
///
/// 对照 AndroidAPS `manager/Utils.kt`。注意 AAPS 的整数编码是**小端**，
/// 且 `intToBytes` 固定 4 字节、`intToTwoBytes` 固定 2 字节。
public enum Hex {

    private static let upperDigits = Array("0123456789ABCDEF".utf8)

    /// 对照 `Utils.bytesToHex`：输出大写十六进制。
    public static func encode(_ bytes: [UInt8]) -> String {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(upperDigits[Int(b >> 4)])
            out.append(upperDigits[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// 对照 `Utils.hexStringToBytes`：忽略大小写，两位一字节。
    /// 非法字符按 AAPS 的 `indexOf == -1` 语义视作 0，不抛异常。
    public static func decode(_ hex: String) -> [UInt8] {
        let chars = Array(hex.utf8)
        let count = chars.count / 2
        var out = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            let hi = nibble(chars[i * 2])
            let lo = nibble(chars[i * 2 + 1])
            out[i] = (hi << 4) | lo
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8 {
        switch c {
        case 0x30...0x39: return c - 0x30           // '0'-'9'
        case 0x41...0x46: return c - 0x41 + 10      // 'A'-'F'
        case 0x61...0x66: return c - 0x61 + 10      // 'a'-'f'
        default: return 0
        }
    }
}

/// 对照 `Utils` 的字节序与整数转换。
public enum EquilBytes {

    /// `Utils.intToBytes`：小端 4 字节。
    public static func intToBytes(_ value: Int) -> [UInt8] {
        let v = UInt32(truncatingIfNeeded: value)
        return [
            UInt8(v & 0xFF),
            UInt8((v >> 8) & 0xFF),
            UInt8((v >> 16) & 0xFF),
            UInt8((v >> 24) & 0xFF)
        ]
    }

    /// `Utils.intToTwoBytes`：小端 2 字节。
    public static func intToTwoBytes(_ value: Int) -> [UInt8] {
        let v = UInt16(truncatingIfNeeded: value)
        return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
    }

    /// `Utils.bytes2Int`：小端 4 字节 → Int。
    public static func bytes2Int(_ bytes: [UInt8]) -> Int {
        Int(bytes[0])
            | (Int(bytes[1]) << 8)
            | (Int(bytes[2]) << 16)
            | (Int(bytes[3]) << 24)
    }

    /// `Utils.bytesToInt(highByte, lowByte)`：`(high << 8) | low`，≥0x8000 时减去 0x8000。
    public static func bytesToInt(_ high: UInt8, _ low: UInt8) -> Int {
        let value = (Int(high) << 8) | Int(low)
        return value >= 0x8000 ? value - 0x8000 : value
    }

    public static func concat(_ arrays: [UInt8]...) -> [UInt8] {
        arrays.flatMap { $0 }
    }

    /// 对照 `Utils.generateRandomPassword`（SecureRandom）。
    public static func randomBytes(_ length: Int) -> [UInt8] {
        (0..<length).map { _ in UInt8.random(in: 0...255) }
    }

    /// 对照 `Utils.decodeSpeedToUH(Double)`：速率 ÷ 0.00625 后向零截断。
    /// 用 `Decimal` 还原 AAPS 的 `BigDecimal(value.toString())` 十进制语义，避免二进制浮点误差。
    public static func decodeSpeedToUH(_ value: Double) -> Int {
        guard let a = Decimal(string: String(value)), let b = Decimal(string: "0.00625") else {
            return Int(value / 0.00625)
        }
        return NSDecimalNumber(decimal: a / b).intValue
    }

    /// 对照 `Utils.basalToByteArray`：2 字节**大端** [hi, lo]。
    public static func basalToByteArray(_ value: Double) -> [UInt8] {
        let v = decodeSpeedToUH(value)
        return [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    /// 对照 `Utils.basalToByteArray2`：2 字节**小端** [lo, hi]。
    public static func basalToByteArray2(_ value: Double) -> [UInt8] {
        let v = decodeSpeedToUH(value)
        return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
    }
}