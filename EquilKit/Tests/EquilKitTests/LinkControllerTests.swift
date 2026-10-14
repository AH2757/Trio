import XCTest
@testable import EquilKit

/// 假传输层：记录调用与写入帧，用于在无蓝牙环境下驱动链路状态机。
final class FakeEquilTransport: EquilTransport {
    weak var delegate: EquilTransportDelegate?
    var targetIdentifier: UUID?
    var targetNamePrefix: String?
    var skipCccSubscription = false
    var writeWithResponse = false
    var isConnected = false

    private(set) var frames: [[UInt8]] = []
    private(set) var startScanCount = 0
    private(set) var stopScanCount = 0
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var notifyValues: [Bool] = []

    func startScan() { startScanCount += 1 }
    func stopScan() { stopScanCount += 1 }
    func connect() { connectCount += 1; isConnected = true }
    func disconnect() { disconnectCount += 1; isConnected = false }
    func write(_ bytes: [UInt8]) { frames.append(bytes) }
    func setNotify(_ enabled: Bool) { notifyValues.append(enabled) }
}

/// 记录收帧的桩命令。
final class StubCmd: BaseCmd {
    private(set) var receivedPackets: [[UInt8]] = []

    override func decodeEquilPacket(_ data: [UInt8]) -> EquilResponse? {
        receivedPackets.append(data)
        return nil
    }

    /// 返回单帧响应，供 ready 路径验证"就绪后写出"。
    override func getEquilResponse() -> EquilResponse? {
        let response = EquilResponse(createTime: 0)
        response.add(EquilLinkFrame.makeFrame(flags: 0x00, indexByte: 0x80, payload: [0x01, 0x02]))
        return response
    }

    override func getNextEquilResponse() -> EquilResponse? {
        getEquilResponse()
    }
}

final class LinkControllerTests: XCTestCase {

    private func makeSettings() -> InMemoryEquilSettings {
        // 32 位 hex = 16 字节，满足 AES-128 密钥长度。
        InMemoryEquilSettings(
            equilDevices: String(repeating: "A", count: 64),
            equilPassword: "00112233445566778899AABBCCDDEEFF",
            bolusRate: EquilConst.bolusRateDefault
        )
    }

    override func setUp() {
        super.setUp()
        EquilCounters.reset()
        EquilOfficialSession.lastPumpToken = 0
    }

    /// 提交命令时，链路层应把命令画像写入传输层并绑定设备名。
    func testWriteCmdConfiguresTransport() {
        let fake = FakeEquilTransport()
        let controller = EquilLinkController(transport: fake)
        let cmd = CmdPair(name: "Equil - ABC123", address: "AA:BB", password: "1234", settings: makeSettings())

        controller.writeCmd(cmd)

        XCTAssertTrue(fake.skipCccSubscription, "CmdPair 走官方画像，应跳过 CCC")
        XCTAssertFalse(fake.writeWithResponse, "AES 域命令用 withoutResponse")
        XCTAssertEqual(fake.targetNamePrefix, "Equil - ABC123")
    }

    /// 未找到目标服务时必须断开，交由重试机制走全新连接。
    func testServiceNotFoundForcesDisconnect() {
        let fake = FakeEquilTransport()
        let controller = EquilLinkController(transport: fake)
        controller.writeCmd(StubCmd(createTime: 0, settings: makeSettings()))
        controller.transportDidConnect()

        controller.transportDidDiscoverServices(hasTargetService: false)

        XCTAssertGreaterThanOrEqual(fake.disconnectCount, 1)
    }

    /// 连接就绪后应写出命令首帧，且链路层 CRC 自洽。
    func testFirstFrameWrittenWhenReady() {
        let fake = FakeEquilTransport()
        let controller = EquilLinkController(transport: fake)
        controller.writeCmd(CmdDevicesGet(settings: makeSettings()))

        controller.transportDidConnect()
        controller.transportDidDiscoverServices(hasTargetService: true)

        XCTAssertEqual(fake.frames.count, 1, "应写出首帧后停下等待写完成回调")
        let first = fake.frames[0]
        XCTAssertTrue(EquilLinkFrame.validate(first), "首帧链路层 CRC 应自洽")
        XCTAssertTrue(EquilLinkFrame.isFirstFrame(first))
    }

    /// 收帧应被路由到当前命令解析，且不改动链路状态。
    func testReceivedDataRoutedToCommand() {
        let fake = FakeEquilTransport()
        let controller = EquilLinkController(transport: fake)
        let cmd = StubCmd(createTime: 0, settings: makeSettings())
        controller.writeCmd(cmd)

        let packet: [UInt8] = [0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0xAA, 0xBB]
        controller.transportDidReceive(packet)

        XCTAssertEqual(cmd.receivedPackets.count, 1)
        XCTAssertEqual(cmd.receivedPackets.first, packet)
    }

    /// 未指定目标画像时（默认 false），连接就绪应走 CCC 订阅而非直接 ready。
    func testCCCSubscriptionPathWhenNotSkipping() {
        let fake = FakeEquilTransport()
        let controller = EquilLinkController(transport: fake)
        // StubCmd 未覆写 preferNoCccSubscription → false → 走订阅路径。
        controller.writeCmd(StubCmd(createTime: 0, settings: makeSettings()))
        controller.transportDidConnect()

        controller.transportDidDiscoverServices(hasTargetService: true)

        XCTAssertEqual(fake.notifyValues, [true], "非跳过画像应请求订阅")
        XCTAssertTrue(fake.frames.isEmpty, "订阅确认前不应写命令帧")

        controller.transportIsReady()
        XCTAssertFalse(fake.frames.isEmpty, "订阅确认后应开始写命令帧")
    }
}

final class EquilTimerTests: XCTestCase {

    func testCancelPreventsExecution() {
        let timer = EquilTimer(queue: DispatchQueue(label: "test.timer"))
        let exp = expectation(description: "block should not run")
        exp.isInverted = true
        timer.schedule(50) { exp.fulfill() }
        timer.cancel()
        wait(for: [exp], timeout: 0.2)
    }

    func testRescheduleReplacesPrevious() {
        let timer = EquilTimer(queue: DispatchQueue(label: "test.timer"))
        var count = 0
        let exp = expectation(description: "latest block runs")
        timer.schedule(200) { count += 1 }
        timer.schedule(20) { count += 1; exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(count, 1, "旧任务应被替换，只执行最新一次")
    }
}