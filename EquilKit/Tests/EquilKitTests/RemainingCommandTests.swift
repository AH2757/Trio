import XCTest
@testable import EquilKit

/// 补齐的 AES 域命令测试：载荷字节布局对照 AndroidAPS `Cmd*.kt`，
/// 以及定位循环的 `decodeConfirm` 条件回发语义。
final class RemainingCommandTests: XCTestCase {

    private let settings = InMemoryEquilSettings(
        equilDevices: String(repeating: "0", count: 64),
        equilPassword: String(repeating: "A", count: 64)
    )

    override func setUp() {
        super.setUp()
        EquilCounters.reset()
    }

    // MARK: - 收帧注入

    /// 用会话密码加密 `plaintext`，按收帧布局（首帧 6B 头 + 4B 消息、续帧每片 10B）
    /// 构造 `cmd.response`，供 `decodeConfirm()` 走完整解密链路。
    private func injectConfirm(_ cmd: BaseCmd, plaintext: [UInt8]) throws {
        let pwd = "00112233445566778899AABBCCDDEEFF"   // 16B = AES-128
        cmd.runPwd = pwd
        let model = try EquilAES.encrypt(key: Hex.decode(pwd), data: plaintext)
        let message = Hex.decode((model.tag ?? "") + (model.iv ?? "") + (model.ciphertext ?? ""))
        XCTAssertGreaterThanOrEqual(message.count, 28)

        let header: [UInt8] = [0x04, 0x04, 0x00, 0x00, 0x00, 0x00]
        var frames: [[UInt8]] = [header + Array(message[0..<4])]
        var offset = 4
        while offset < message.count {
            let end = min(offset + 10, message.count)
            frames.append(Array(message[offset..<end]))
            offset = end
        }

        let response = EquilResponse(createTime: 0)
        for (i, payload) in frames.enumerated() {
            let seq = i * 10
            let isLast = i == frames.count - 1
            let indexByte = UInt8((seq | (isLast ? 0x80 : 0x00)) & 0xFF)
            response.add(EquilLinkFrame.makeFrame(flags: UInt8(seq & 0xFF), indexByte: indexByte, payload: payload))
        }
        cmd.response = response
    }

    // MARK: - CmdHistoryGet

    func testHistoryGetPayloads() {
        let cmd = CmdHistoryGet(currentIndex: 5, settings: settings)
        XCTAssertEqual(
            cmd.getFirstData(),
            [0x0A, 0x00, 0x00, 0x00, 0x02, 0x01, 0x05, 0x00, 0x00, 0x00]
        )
        EquilCounters.pumpReqIndex = 10
        XCTAssertEqual(cmd.getNextData(), [0x0A, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01])
    }

    func testHistoryGetConfirmParsing() {
        let cmd = CmdHistoryGet(currentIndex: 5, settings: settings)
        var data = [UInt8](repeating: 0, count: 24)
        data[6] = 1     // year
        data[7] = 2     // month
        data[8] = 3     // day
        data[9] = 4     // hour
        data[10] = 5    // minute
        data[11] = 6    // second
        data[12] = 50   // battery
        data[13] = 100  // medicine
        data[14] = 0x01; data[15] = 0x00 // rate = (data[15]<<8)|data[14] = 1
        data[16] = 0x02; data[17] = 0x00 // largeRate = 2
        data[18] = 0x03; data[19] = 0x00 // index = 3
        data[21] = 7    // type
        data[22] = 8    // level
        data[23] = 9    // parm

        cmd.decodeConfirmData(data)

        XCTAssertTrue(cmd.cmdStatus)
        XCTAssertEqual(cmd.year, 1)
        XCTAssertEqual(cmd.month, 2)
        XCTAssertEqual(cmd.day, 3)
        XCTAssertEqual(cmd.hour, 4)
        XCTAssertEqual(cmd.minute, 5)
        XCTAssertEqual(cmd.second, 6)
        XCTAssertEqual(cmd.battery, 50)
        XCTAssertEqual(cmd.medicine, 100)
        XCTAssertEqual(cmd.rate, 1)
        XCTAssertEqual(cmd.largeRate, 2)
        XCTAssertEqual(cmd.index, 3)
        XCTAssertEqual(cmd.type, 7)
        XCTAssertEqual(cmd.level, 8)
        XCTAssertEqual(cmd.parm, 9)
        XCTAssertEqual(cmd.resultIndex, 3)
        XCTAssertNotNil(cmd.rawHistoryData, "currentIndex != 0 应保留原始记录供解码")
    }

    /// currentIndex == 0 是游标探测，不入库。
    func testHistoryGetIndexZeroSkipsRecord() {
        let cmd = CmdHistoryGet(currentIndex: 0, settings: settings)
        cmd.decodeConfirmData([UInt8](repeating: 0, count: 24))
        XCTAssertTrue(cmd.cmdStatus)
        XCTAssertNil(cmd.rawHistoryData)
    }

    // MARK: - CmdStepSet

    func testStepSetPayloads() {
        let cmd = CmdStepSet(sendConfig: true, step: 80, settings: settings)
        XCTAssertEqual(
            cmd.getFirstData(),
            [0x0A, 0x00, 0x00, 0x00, 0x01, 0x07, 0x50, 0x00, 0x00, 0x00]
        )
        EquilCounters.pumpReqIndex = 10
        XCTAssertEqual(
            cmd.getNextData(),
            [0x0A, 0x00, 0x00, 0x00, 0x00, 0x07, 0x01, 0x00, 0x00, 0x00, 0x00]
        )
    }

    /// sendConfig=false 时 decodeConfirm 只解析确认段、不回发第三阶段帧。
    func testStepSetWithoutConfigSendsNothing() throws {
        let cmd = CmdStepSet(sendConfig: false, step: 80, settings: settings)
        try injectConfirm(cmd, plaintext: [UInt8](repeating: 0, count: 8))
        XCTAssertNil(try cmd.decodeConfirm())
        XCTAssertTrue(cmd.cmdStatus)
    }

    /// sendConfig=true 时 decodeConfirm 回发第三阶段帧。
    func testStepSetWithConfigSendsNextFrame() throws {
        let cmd = CmdStepSet(sendConfig: true, step: 80, settings: settings)
        try injectConfirm(cmd, plaintext: [UInt8](repeating: 0, count: 8))
        let resp = try cmd.decodeConfirm()
        XCTAssertNotNil(resp)
        XCTAssertFalse(resp?.send.isEmpty ?? true)
        XCTAssertTrue(cmd.cmdStatus)
    }

    // MARK: - CmdResistanceGet

    func testResistanceGetPayloads() {
        let cmd = CmdResistanceGet(firmwareVersion: "1.6", settings: settings)
        XCTAssertEqual(cmd.getFirstData(), [0x0A, 0x00, 0x00, 0x00, 0x02, 0x02])
        EquilCounters.pumpReqIndex = 10
        XCTAssertEqual(cmd.getNextData(), [0x0A, 0x00, 0x00, 0x00, 0x00, 0x02, 0x01])
    }

    /// fw 1.x 世代阈值 300：接触阻力 306 → enacted，且不回发第三阶段帧。
    func testResistanceThresholdFirmware1x() throws {
        let cmd = CmdResistanceGet(firmwareVersion: "1.6", settings: settings)
        var plain = [UInt8](repeating: 0, count: 8)
        plain[6] = 306 & 0xFF; plain[7] = (306 >> 8) & 0xFF
        try injectConfirm(cmd, plaintext: plain)
        XCTAssertNil(try cmd.decodeConfirm(), "解析后不回发第三阶段帧")
        XCTAssertEqual(cmd.value, 306)
        XCTAssertEqual(cmd.threshold, 300)
        XCTAssertTrue(cmd.enacted)
        XCTAssertTrue(cmd.cmdStatus)
    }

    /// 其他世代阈值 500：同一读数 306 → 未达阈值。
    func testResistanceThresholdOtherFirmware() {
        let cmd = CmdResistanceGet(firmwareVersion: "2.0", settings: settings)
        var data = [UInt8](repeating: 0, count: 8)
        data[6] = 306 & 0xFF; data[7] = (306 >> 8) & 0xFF
        cmd.decodeConfirmData(data)
        XCTAssertEqual(cmd.value, 306)
        XCTAssertEqual(cmd.threshold, 500)
        XCTAssertFalse(cmd.enacted)
    }

    // MARK: - CmdInsulinChange

    func testInsulinChangePayloads() {
        let cmd = CmdInsulinChange(settings: settings)
        // 32000 = 0x7D00 → LE [0x00, 0x7D, 0x00, 0x00]
        XCTAssertEqual(
            cmd.getFirstData(),
            [0x0A, 0x00, 0x00, 0x00, 0x01, 0x06, 0x00, 0x7D, 0x00, 0x00]
        )
        EquilCounters.pumpReqIndex = 10
        XCTAssertEqual(
            cmd.getNextData(),
            [0x0A, 0x00, 0x00, 0x00, 0x00, 0x06, 0x01, 0x00, 0x00, 0x00, 0x00]
        )
    }

    func testInsulinChangeConfirmStatus() {
        let cmd = CmdInsulinChange(settings: settings)
        cmd.decodeConfirmData([0, 0, 0, 0, 0, 0, 3])
        XCTAssertEqual(cmd.status, 3)
        XCTAssertTrue(cmd.cmdStatus)
        XCTAssertEqual(cmd.getEventType(), .changeInsulin)
    }

    // MARK: - CmdExtendedBolusSet

    func testExtendedBolusPayload() {
        let cmd = CmdExtendedBolusSet(insulin: 1.0, durationInMinutes: 60, cancel: false, settings: settings)
        XCTAssertEqual(cmd.step, 160)
        XCTAssertEqual(cmd.pumpTime, 3600)
        // [idx(4)] + [0x01,0x03] + zero + zero + step + pumpTime
        XCTAssertEqual(
            cmd.getFirstData(),
            [0x0A, 0x00, 0x00, 0x00, 0x01, 0x03,
             0x00, 0x00, 0x00, 0x00,
             0x00, 0x00, 0x00, 0x00,
             0xA0, 0x00, 0x00, 0x00,
             0x10, 0x0E, 0x00, 0x00]
        )
        XCTAssertEqual(cmd.getEventType(), .setExtendedBolus)
    }

    func testExtendedBolusCancel() {
        let cmd = CmdExtendedBolusSet(insulin: 0.0, durationInMinutes: 60, cancel: true, settings: settings)
        XCTAssertEqual(cmd.step, 0)
        XCTAssertEqual(cmd.pumpTime, 0)
        XCTAssertEqual(cmd.getEventType(), .cancelExtendedBolus)
    }

    // MARK: - CmdDevicesOldGet

    /// 旧设备查询首帧是硬编码明文帧，链路层校验须通过。
    func testDevicesOldGetHardcodedFrame() {
        let cmd = CmdDevicesOldGet(settings: settings)
        guard let resp = cmd.getEquilResponse() else { return XCTFail("getEquilResponse 返回 nil") }
        XCTAssertEqual(resp.send.count, 1)
        let frame = resp.send[0]
        XCTAssertEqual(frame, [0x00, 0x00, 0x0E, 0x00, 0x80, 0x78, 0x00, 0x00, 0x00, 0x00, 0x01, 0x7B, 0x02, 0x00])
        XCTAssertTrue(EquilLinkFrame.validate(frame))
    }

    /// 固件版本从密文 [12].[13] 读取，`isSupport` 用 >= 1.0 判定。
    func testDevicesOldGetFirmwareParsing() throws {
        let cmd = CmdDevicesOldGet(settings: settings)
        // 收帧：首帧载荷 = 6B 头 + 4B，末 2 字节为密文尾；构造末 2 字节 = 1,6（固件 1.6）。
        // 首帧载荷 [4],[5] 即 decodeModel 解出的 code（此处置 0 → "0000"）。
        let p0: [UInt8] = [0x04, 0x04, 0x00, 0x00, 0x00, 0x00, 0, 0, 0, 0, 0, 1, 6]
        let f0 = EquilLinkFrame.makeFrame(flags: 0x00, indexByte: 0x80, payload: p0)
        let response = EquilResponse(createTime: 0)
        response.add(f0)
        cmd.response = response

        let model = try cmd.decodeModel()
        XCTAssertEqual(model.ciphertext, Hex.encode([1, 6]).lowercased())
        XCTAssertEqual(model.tag, "")
        XCTAssertEqual(model.iv, "")
        XCTAssertEqual(model.code, "0000")
    }
}