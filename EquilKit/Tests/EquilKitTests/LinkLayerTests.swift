import XCTest
@testable import EquilKit

final class LinkLayerTests: XCTestCase {

    func testMakeFrameRoundTripsThroughValidate() {
        let payload: [UInt8] = [0x02, 0x00, 0x11, 0x22]
        let frame = EquilLinkFrame.makeFrame(flags: 0x00, indexByte: 0x80, payload: payload)
        XCTAssertEqual(frame[0], 0x00)
        XCTAssertEqual(frame[1], 0x00)
        XCTAssertEqual(frame[2], UInt8(6 + payload.count))
        XCTAssertEqual(Array(frame[6...]), payload)
        XCTAssertTrue(EquilLinkFrame.validate(frame))
    }

    func testMakeFrameComputesCRC() {
        // 手工构造等价于实测"设备查询"首帧的载荷，校验 CRC 一致。
        let payload: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x71, 0xE5, 0x02, 0x00, 0x00, 0x00]
        let frame = EquilLinkFrame.makeFrame(flags: 0x00, indexByte: 0x00, payload: payload)
        XCTAssertEqual(frame[5], 0x4A)
    }

    func testFirstAndEndFrameFlags() {
        let first = EquilLinkFrame.makeFrame(flags: 0x00, indexByte: 0x00, payload: [0x01])
        XCTAssertTrue(EquilLinkFrame.isFirstFrame(first))
        XCTAssertFalse(EquilLinkFrame.isEndFrame(first))

        let last = EquilLinkFrame.makeFrame(flags: 0x0A, indexByte: 0x80, payload: [0x01])
        XCTAssertFalse(EquilLinkFrame.isFirstFrame(last))
        XCTAssertTrue(EquilLinkFrame.isEndFrame(last))
    }

    func testIndexHelpers() {
        XCTAssertEqual(EquilLinkFrame.messageIndex([0, 0, 0, 0, 0x82]), 0x02)
        XCTAssertTrue(EquilLinkFrame.isEndByte(0x82))
        XCTAssertFalse(EquilLinkFrame.isEndByte(0x02))
        XCTAssertEqual(EquilLinkFrame.clearingEndBit(0x82), 0x02)
        XCTAssertEqual(EquilLinkFrame.settingEndBit(0x02), 0x82)
    }
}