import XCTest
@testable import EquilKit

/// crc8Maxim / crc16 对照实测帧样本。
///
/// 样本取自 AndroidAPS 项目文档 `equil-official-protocol-handbook.md` §4 记录的官方域首帧，
/// 已用 `tools/verify_protocol.py` 独立复现确认。
final class CRCTests: XCTestCase {

    private let samples: [(String, String)] = [
        ("设备查询", "0000100000 4A 0000000071E502000000"),
        ("时间同步", "0000100002 F6 050516BE8C9701001A08"),
        ("状态查询(实时)", "00000E0085 47 0404965C1CA50200"),
        ("基础率表读取", "00000F0080 D3 04040000BFA40202FF"),
        ("历史记录查询", "00000E0082 C4 0404D32958720203"),
        ("推杆步进", "0000100036 29 0404D4EC876201075000"),
        ("ACK泵通知", "00000F00C7 16 04048088B4FA000001"),
        ("限值写入", "0000100009 D6 040475E9A50E0106007D")
    ]

    func testCRC8MatchesDocumentedFrames() {
        for (name, raw) in samples {
            let frame = Hex.decode(raw.replacingOccurrences(of: " ", with: ""))
            XCTAssertEqual(frame.count, Int(frame[2]), "\(name): len 字段与实际长度不一致")
            XCTAssertEqual(
                EquilCRC.crc8Maxim(Array(frame[0..<5])),
                frame[5],
                "\(name): crc8Maxim 不匹配"
            )
        }
    }

    func testLinkFrameValidateAcceptsDocumentedFrames() {
        for (name, raw) in samples {
            let frame = Hex.decode(raw.replacingOccurrences(of: " ", with: ""))
            XCTAssertTrue(EquilLinkFrame.validate(frame), "\(name): 链路层校验应通过")
        }
    }

    func testLinkFrameValidateRejectsCorruptedCRC() {
        let frame = Hex.decode("00001000004A0000000071E502000000")
        var broken = frame
        broken[5] ^= 0xFF
        XCTAssertFalse(EquilLinkFrame.validate(broken))
    }

    func testCRC16ReferenceVector() {
        // 反射 CRC16（poly 0xA001，初值 0xFFFF），标准校验串 "123456789" = 0x4B37。
        XCTAssertEqual(Hex.encode(EquilCRC.crc16(Array("123456789".utf8))), "4B37")
        XCTAssertEqual(Hex.encode(EquilCRC.crc16([])), "FFFF")
    }
}