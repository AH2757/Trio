import XCTest
@testable import EquilKit

/// 官方域命令测试：帧构造对照 `equil-official-protocol-handbook.md` §4 实测样本，
/// 以及 op5/op6 确认状态机行为。
final class OfficialCommandTests: XCTestCase {

    private let settings = InMemoryEquilSettings()

    override func setUp() {
        super.setUp()
        EquilCounters.reset()
        EquilOfficialSession.lastPumpToken = 0
    }

    // MARK: - 帧构造对照实测样本

    /// 设备查询首帧与官方四日志样本字节级一致（token 固定 0x71E5、ack=0000、idx=00）。
    func testDeviceQueryFirstFrameMatchesDocumentedSample() {
        let cmd = OfficialDeviceQuery(settings: settings)
        guard let resp = cmd.getEquilResponse() else { return XCTFail("getEquilResponse 返回 nil") }

        XCTAssertEqual(resp.send.count, 2, "4B 数据应分两帧")
        XCTAssertEqual(resp.send[0], Hex.decode("00001000004A0000000071E502000000"))
    }

    /// 基础率同步流入口：ack=0000 + idx=00 + data=FF，单帧结束位。
    func testBasalReadFlowStartFrame() {
        let cmd = OfficialBasalRead(settings: settings, empty: false, flowStart: true)
        guard let resp = cmd.getEquilResponse() else { return XCTFail("getEquilResponse 返回 nil") }

        XCTAssertEqual(resp.send.count, 1)
        let frame = resp.send[0]
        XCTAssertTrue(EquilLinkFrame.validate(frame))
        XCTAssertEqual(frame[2], 0x0F, "帧长应为 15")
        XCTAssertEqual(frame[3], 0x00, "首帧 flags")
        XCTAssertEqual(frame[4], 0x80, "末帧 idx 应置结束位且流程起始 idx=00")

        let payload = Array(frame[6...])
        XCTAssertEqual(Array(payload[0..<2]), [0x04, 0x04], "端口 4/4")
        XCTAssertEqual(Array(payload[2..<4]), [0x00, 0x00], "ack 固定 0000")
        XCTAssertEqual(payload[6], 0x02, "op=read")
        XCTAssertEqual(payload[7], 0x02, "param=2")
        XCTAssertEqual(payload[8], 0xFF, "data=FF")
    }

    /// 推杆步进 80 步：data 前缀 LE u32 = `50 00 00 00`。
    func testPushrodStepPayload() {
        let cmd = OfficialPushrodStep(settings: settings, steps: 80)
        guard let resp = cmd.getEquilResponse() else { return XCTFail("getEquilResponse 返回 nil") }

        let payload = Array(resp.send[0][6...])
        XCTAssertEqual(Array(payload[0..<2]), [0x04, 0x04])
        XCTAssertEqual(payload[6], 0x01, "op=write")
        XCTAssertEqual(payload[7], 0x07, "param=7")
        XCTAssertEqual(Array(payload[8..<10]), [0x50, 0x00], "步数 LE u32 前缀")
    }

    /// 推杆回退 32000 步：data 前缀 LE u32 = `00 7D 00 00`。
    func testConfigSetRewindPayload() {
        let cmd = OfficialConfigSet(settings: settings, maxSteps: 32000)
        guard let resp = cmd.getEquilResponse() else { return XCTFail("getEquilResponse 返回 nil") }

        let payload = Array(resp.send[0][6...])
        XCTAssertEqual(Array(payload[0..<2]), [0x04, 0x04])
        XCTAssertEqual(payload[6], 0x01, "op=write")
        XCTAssertEqual(payload[7], 0x06, "param=6")
        XCTAssertEqual(Array(payload[8..<10]), [0x00, 0x7D], "回退步数 LE u32 前缀")
    }

    /// 历史记录查询（op2/param3）参数映射。
    func testParam3ReadFrame() {
        let cmd = OfficialParam3Read(settings: settings)
        guard let resp = cmd.getEquilResponse() else { return XCTFail("getEquilResponse 返回 nil") }

        let payload = Array(resp.send[0][6...])
        XCTAssertEqual(Array(payload[0..<2]), [0x04, 0x04])
        XCTAssertEqual(payload[6], 0x02, "op=read")
        XCTAssertEqual(payload[7], 0x03, "param=3")
    }

    /// TBR：0.5 U/h × 30min → [40, 1800]；取消 → 8B 全零。
    func testTempBasalSetPayload() {
        let set = OfficialTempBasalSet(settings: settings, rate: 0.5, durationMinutes: 30, cancel: false)
        guard let resp = set.getEquilResponse() else { return XCTFail("getEquilResponse 返回 nil") }
        XCTAssertEqual(set.commandData, EquilBytes.intToBytes(40) + EquilBytes.intToBytes(1800))

        let payload = Array(resp.send[0][6...])
        XCTAssertEqual(Array(payload[0..<2]), [0x04, 0x04])
        XCTAssertEqual(Array(payload[2..<4]), [0x00, 0x00], "TBR 独立流程 ack=0000")
        XCTAssertEqual(payload[6], 0x01, "op=write")
        XCTAssertEqual(payload[7], 0x04, "param=4")

        let cancel = OfficialTempBasalSet(settings: settings, rate: 0, durationMinutes: 0, cancel: true)
        XCTAssertEqual(cancel.commandData, [UInt8](repeating: 0, count: 8))
    }

    /// 大剂量：1.00U → [160, 20, 0, 0]（速率 20=2.0U/min）。
    func testBolusSetPayload() {
        let cmd = OfficialBolusSet(settings: settings, insulin: 1.0, rateX10: 20)
        XCTAssertEqual(
            cmd.commandData,
            EquilBytes.intToBytes(160) + EquilBytes.intToBytes(20) + EquilBytes.intToBytes(0) + EquilBytes.intToBytes(0)
        )
    }

    // MARK: - op5 / op6 确认状态机

    /// 设备查询应答：匹配 token 的 op5 通知 → onResponse 取数 + markDone + 回 op0 ACK。
    func testNotifyCompletesQueryAndEmitsAck() {
        let cmd = OfficialDeviceQuery(settings: settings)
        _ = cmd.getEquilResponse() // 固定 token 0x71E5 写入 msgToken

        // 泵 op5 通知：ack 回显我方 token(0x71E5)，token=0x1234，data 14B（SN 6B + fw 于 [12][13]）。
        let data: [UInt8] = [1, 2, 3, 4, 5, 6, 0, 2, 1, 0, 0, 0, 1, 2]
        let pumpMsg = OfficialFrame.build(
            createTime: 0, srcPort: 0, dstPort: 0,
            operation: OfficialFrame.opNotify, parameter: 0, data: data,
            ackToken: 0x71E5, token: 0x1234, msgIndex: 0
        )

        var ack: EquilResponse?
        for frame in pumpMsg.send { ack = cmd.decodeEquilPacket(frame) ?? ack }

        XCTAssertTrue(cmd.cmdStatus, "匹配的 op5 应完成查询命令")
        XCTAssertEqual(cmd.serialNumberHex, "010203040506")
        XCTAssertEqual(cmd.firmwareVersion, "1.2")
        XCTAssertTrue(cmd.isSupport())
        XCTAssertEqual(EquilOfficialSession.lastPumpToken, 0x1234, "确认链游标应更新为泵 token")

        guard let ackResp = ack, let ackFrame = ackResp.send.first else {
            return XCTFail("应生成 op0 ACK")
        }
        let payload = Array(ackFrame[6...])
        XCTAssertEqual(payload[6], OfficialFrame.opAck, "ACK op=0")
        XCTAssertEqual(Array(payload[2..<4]), [0x12, 0x34], "ACK 回显泵 token")
        XCTAssertEqual(Array(payload[8...]), [0x01], "ACK data=01")
    }

    /// 非本命令的迟到 op5（ack 不匹配）应被忽略：不完成、不 ACK。
    func testLateNotifyIgnored() {
        let cmd = OfficialDeviceQuery(settings: settings)
        _ = cmd.getEquilResponse()

        let pumpMsg = OfficialFrame.build(
            createTime: 0, srcPort: 0, dstPort: 0,
            operation: OfficialFrame.opNotify, parameter: 0, data: [UInt8](repeating: 0, count: 14),
            ackToken: 0xFFFF, token: 0x1234, msgIndex: 0
        )
        var ack: EquilResponse?
        for frame in pumpMsg.send { ack = cmd.decodeEquilPacket(frame) ?? ack }

        XCTAssertFalse(cmd.cmdStatus, "token 不匹配不应完成命令")
        XCTAssertNil(ack, "token 不匹配不应生成 ACK")
    }

    /// 写命令（时间同步）：op6 完成应答 → markDone + 回 op0 ACK。
    func testDoneAckCompletesWriteCommand() {
        let cmd = OfficialTimeSet(settings: settings)
        guard let req = cmd.getEquilResponse() else { return XCTFail("getEquilResponse 返回 nil") }
        // 取回本次请求 token（写命令 token 随机，需从请求帧解析）。
        let reqPayload = Array(req.send[0][6...])
        let reqToken = (Int(reqPayload[4]) << 8) | Int(reqPayload[5])

        let pumpMsg = OfficialFrame.build(
            createTime: 0, srcPort: 0x05, dstPort: 0x05,
            operation: OfficialFrame.opDone, parameter: 0, data: [0x01],
            ackToken: reqToken, token: 0x2222, msgIndex: 0
        )
        var ack: EquilResponse?
        for frame in pumpMsg.send { ack = cmd.decodeEquilPacket(frame) ?? ack }

        XCTAssertTrue(cmd.cmdStatus, "匹配的 op6 应完成写命令")
        XCTAssertNotNil(ack, "acksDone=true 应回 op0 ACK")
    }
}