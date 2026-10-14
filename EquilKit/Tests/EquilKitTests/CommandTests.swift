import XCTest
@testable import EquilKit

final class CommandTests: XCTestCase {

    override func setUp() {
        super.setUp()
        EquilCounters.reset()
    }

    // MARK: - sn 转换

    func testConvertStringPrefixesEachCharWithZero() {
        XCTAssertEqual(BaseCmd.convertString("D02563"), "0D0002050603")
    }

    // MARK: - 命令载荷（对照协议手册实测帧）

    func testTempBasalSetPayload() {
        // 手册 TBR 样本：0.5 U/h × 30 min → step=0x28(40)，time=0x0708(1800s)
        let cmd = CmdTempBasalSet(insulin: 0.5, duration: 30, settings: InMemoryEquilSettings())
        XCTAssertEqual(cmd.step, 40)
        XCTAssertEqual(cmd.pumpTime, 1800)

        let payload = cmd.getFirstData()
        let expected: [UInt8] = [
            0x0A, 0x00, 0x00, 0x00,   // pumpReqIndex = 10（小端）
            0x01, 0x04,               // op / param
            0x28, 0x00, 0x00, 0x00,   // step = 40（小端）
            0x08, 0x07, 0x00, 0x00    // pumpTime = 1800（小端）
        ]
        XCTAssertEqual(payload, expected)
    }

    func testLargeBasalStepAndTime() {
        // 1.0 U，默认速率 1.5 U/min → step = round(1/0.05*8) = 160，stepTime = round(60/1.5) = 40
        let cmd = CmdLargeBasalSet(insulin: 1.0, settings: InMemoryEquilSettings())
        XCTAssertEqual(cmd.step, 160)
        XCTAssertEqual(cmd.stepTime, 40)
    }

    func testInsulinGetPayloadPrefix() {
        let cmd = CmdInsulinGet(settings: InMemoryEquilSettings())
        let payload = cmd.getFirstData()
        XCTAssertEqual(payload, [0x0A, 0x00, 0x00, 0x00, 0x02, 0x07])
    }

    // MARK: - 收帧还原

    func testDecodeModelRecoversCipherModel() throws {
        // 按收帧布局构造：首帧载荷 = 6B 头 + 4B 消息；续帧每片 10B。
        let tag = (0..<16).map { UInt8($0) }
        let iv = (16..<28).map { UInt8($0) }
        let cipher = [UInt8](arrayLiteral: 0xA0, 0xA1, 0xA2, 0xA3)
        let message = tag + iv + cipher
        XCTAssertEqual(message.count, 32)

        let header: [UInt8] = [0x04, 0x04, 0x00, 0x00, 0xAA, 0xBB]
        let p0 = header + Array(message[0..<4])
        let p1 = Array(message[4..<14])
        let p2 = Array(message[14..<24])
        let p3 = Array(message[24..<32])

        let frames = [
            EquilLinkFrame.makeFrame(flags: 0x00, indexByte: 0x00, payload: p0),
            EquilLinkFrame.makeFrame(flags: 0x0A, indexByte: 0x01, payload: p1),
            EquilLinkFrame.makeFrame(flags: 0x14, indexByte: 0x02, payload: p2),
            EquilLinkFrame.makeFrame(flags: 0x1E, indexByte: 0x83, payload: p3)
        ]

        let cmd = CmdModelGet(settings: InMemoryEquilSettings())
        let response = EquilResponse(createTime: 0)
        frames.forEach { response.add($0) }
        cmd.response = response

        let model = try cmd.decodeModel()
        XCTAssertEqual(model.tag, Hex.encode(tag).lowercased())
        XCTAssertEqual(model.iv, Hex.encode(iv).lowercased())
        XCTAssertEqual(model.ciphertext, Hex.encode(cipher).lowercased())
        XCTAssertEqual(model.code, "AABB")
    }

    func testDecodeModelThrowsOnIncompleteSequence() {
        let cmd = CmdModelGet(settings: InMemoryEquilSettings())
        let response = EquilResponse(createTime: 0)
        // 缺中间帧：flags 0x00 后直接 0x14，序列不连续。
        response.add(EquilLinkFrame.makeFrame(flags: 0x00, indexByte: 0x00, payload: [UInt8](repeating: 0, count: 10)))
        response.add(EquilLinkFrame.makeFrame(flags: 0x14, indexByte: 0x02, payload: [UInt8](repeating: 0, count: 10)))
        cmd.response = response
        XCTAssertThrowsError(try cmd.decodeModel())
    }

    // MARK: - 分帧

    func testResponseCmdProducesValidFrames() {
        let settings = InMemoryEquilSettings(
            equilDevices: String(repeating: "0", count: 64),
            equilPassword: String(repeating: "A", count: 64)
        )
        let cmd = CmdModelGet(settings: settings)
        guard let response = cmd.getEquilResponse() else {
            return XCTFail("getEquilResponse 返回 nil")
        }
        XCTAssertGreaterThan(response.send.count, 1)

        for (i, frame) in response.send.enumerated() {
            XCTAssertTrue(EquilLinkFrame.validate(frame), "第 \(i) 帧链路层校验失败")
            XCTAssertEqual(frame[3], UInt8((10 * i) & 0xFF), "第 \(i) 帧 flags 应为 10*i")
        }
        let last = response.send[response.send.count - 1]
        XCTAssertTrue(EquilLinkFrame.isEndFrame(last), "末帧应置结束位")
        XCTAssertEqual(last[2], UInt8(last.count))
    }
}