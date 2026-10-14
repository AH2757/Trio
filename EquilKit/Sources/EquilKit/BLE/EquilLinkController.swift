import Foundation

/// 链路状态，对照 AAPS `EventPumpStatusChanged.Status` 的子集。
public enum EquilLinkStatus: Equatable {
    case disconnected
    case connected
}

/// BLE 链路状态机，对照 AndroidAPS `ble/EquilBLE.kt`。
///
/// 职责：把 `EquilTransport`（Core Bluetooth）的异步回调，串成 AAPS 那套
/// "连接 → 分帧写 → 收帧还原 → 超时重写 → 用完即走断开" 的流程。
///
/// 与 AAPS 的差异（已在 `docs/09-iOS BLE 移植说明.md` 记录）：
/// - iOS 无 `createBond`，不做系统配对；
/// - iOS 无 `requestConnectionPriority`，连接参数由系统协商；
/// - **CCC 画像**：iOS 只能用 `setNotifyValue` 订阅（会写 2902），
///   与 AAPS "跳过 CCC 才进控制端口" 的画像存在冲突，需真机验证（见下方 `skipCCC`）。
///
/// 线程模型：所有公开入口用递归锁串行化；定时器回调统一回到 `EquilTimer` 的队列。
public final class EquilLinkController: EquilTransportDelegate {

    public weak var transport: EquilTransport?

    // MARK: - 对外回调

    /// 链路状态变化。
    public var onStatusChange: ((EquilLinkStatus) -> Void)?
    /// 扫描到泵广播：`(广播原始字节, 是否来自周期扫描)`。
    public var onAdvertisement: (([UInt8], Bool) -> Void)?
    /// 查询队列是否有待执行命令（auto-unpair 让位判定）。
    public var pumpQueuePending: (() -> Bool)?
    /// 是否处于电量追赶窗口（决定周期扫描间隔）。
    public var isBatteryCatchingUp: (() -> Bool)?

    // MARK: - 状态

    public private(set) var isConnected = false
    public private(set) var isGattReady = false
    public private(set) var connecting = false
    public private(set) var isDeviceDiscoverable = false
    public private(set) var sessionValid = false
    public private(set) var mtuSize = EquilGatt.defaultMtu
    public private(set) var autoScan = false

    private var keepAlive = false
    private var directConnectFailed = false

    private var baseCmd: BaseCmd?
    private var preCmd: BaseCmd?
    private var equilResponse: EquilResponse?
    private var indexData = 0
    private var isWriting = false
    private var consecutiveWriteTimeoutCount = 0

    // confirm 应答停滞监视
    private var lastRxTime: Int64 = 0
    private var confirmRewriteCount = 0
    private var confirmWatchScheduledAt: Int64 = 0

    // 连接失败退避（对照 Android GATT 133 计数）
    private var consecutiveConnectFailureCount = 0
    private var lastConnectFailureTime: Int64 = 0

    // 会话持久化（跨重连复用，泵未解配前会话仍有效）
    private var sessionRunCode: String?
    private var sessionRunPwd: String?
    private var sessionReqIndex = 0
    private var sessionRspIndex = -1

    private let lock = NSRecursiveLock()

    // MARK: - 定时器

    private let scanTimeoutTimer = EquilTimer()
    private let connectTimeoutTimer = EquilTimer()
    private let closeBleAutoTimer = EquilTimer()
    private let writeTimeoutTimer = EquilTimer()
    private let writeContinueTimer = EquilTimer()
    private let confirmWatchTimer = EquilTimer()
    private let periodicScanTimer = EquilTimer()
    private let periodicScanTimeoutTimer = EquilTimer()
    private let preConnectTimer = EquilTimer()
    private let connectDelayTimer = EquilTimer()

    public init(transport: EquilTransport? = nil) {
        if let transport = transport {
            attach(transport: transport)
        }
    }

    /// 绑定传输实现并把本控制器设为它的代理。
    public func attach(transport: EquilTransport) {
        self.transport = transport
        transport.delegate = self
    }

    // MARK: - 会话管理

    /// 清空持久化会话与全局计数器。
    public func resetSession() {
        lock.lock(); defer { lock.unlock() }
        EquilLog.debug("resetSession: clearing saved session")
        sessionRunCode = nil
        sessionRunPwd = nil
        sessionReqIndex = 0
        sessionRspIndex = -1
        sessionValid = false
        EquilCounters.reqIndex = 0
        EquilCounters.rspIndex = -1
    }

    /// 标记当前连接已建立可用会话（配对成功后由上层调用）。
    public func markSessionValid() {
        lock.lock(); defer { lock.unlock() }
        sessionValid = true
    }

    // MARK: - 命令入口

    /// 提交一条命令。对照 `EquilBLE.writeCmd`。
    public func writeCmd(_ cmd: BaseCmd) {
        lock.lock(); defer { lock.unlock() }
        EquilLog.debug("writeCmd \(cmd.statusDescription)")

        // CmdPair 需要全新连接：泵处理上一命令确认期间无法响应重新配对。
        if cmd is CmdPair && isConnected {
            EquilLog.info("writeCmd: CmdPair requires fresh connection, disconnecting")
            disconnectLocked()
        }
        // 官方域命令不能复用 CmdPair(legacy) 的连接：泵按"连接+协议域"维护会话。
        if cmd is EquilOfficialCommand && isConnected && preCmd is CmdPair {
            EquilLog.info("writeCmd: official after CmdPair requires fresh connection, disconnecting")
            disconnectLocked()
        }

        // 清理残留写入状态，防止陈旧数据包被写出。
        isWriting = false
        equilResponse = nil
        indexData = 0
        writeTimeoutTimer.cancel()
        confirmRewriteCount = 0
        confirmWatchTimer.cancel()

        // iOS 侧设备匹配：绑定名字前缀（首配）或沿用已存标识。
        if let pair = cmd as? CmdPair {
            transport?.targetNamePrefix = pair.deviceName
        } else if let unpair = cmd as? CmdUnPair {
            transport?.targetNamePrefix = unpair.deviceName
        }
        transport?.skipCccSubscription = cmd.preferNoCccSubscription
        transport?.writeWithResponse = (cmd is EquilOfficialCommand)

        baseCmd = cmd
        autoScan = (cmd is CmdModelGet) || (cmd is CmdInsulinGet)

        if isConnected && isGattReady && cmd.isPairStep() {
            readyLocked()
        } else if isConnected && isGattReady && sessionValid {
            if let pre = preCmd {
                cmd.runCode = pre.runCode
                cmd.runPwd = pre.runPwd
            }
            nextCmdLocked()
        } else if isConnected && isGattReady && !sessionValid {
            readyLocked()
        } else if isConnected && !isGattReady {
            EquilLog.debug("writeCmd: GATT not ready, deferring")
            if let pre = preCmd {
                cmd.runCode = pre.runCode
                cmd.runPwd = pre.runPwd
            }
        } else if connecting {
            EquilLog.debug("writeCmd: already connecting, deferring")
        } else {
            if !directConnectFailed {
                connectEquilLocked()
            } else {
                findEquilLocked()
            }
            connectTimeoutTimer.schedule(Int64(cmd.connectTimeOut)) { [weak self] in
                self?.onConnectTimeout()
            }
        }
        preCmd = cmd
        closeBleAutoTimer.cancel()
        keepAlive = false
    }

    /// 取消挂起命令（重试全失败后调用），防止延迟投递造成状态分叉。
    public func cancelPendingCommand() {
        lock.lock(); defer { lock.unlock() }
        if baseCmd != nil {
            EquilLog.info("cancelPendingCommand: clearing pending command")
            baseCmd = nil
        }
    }

    // MARK: - 发送流程

    /// 对照 `EquilBLE.ready`：连接就绪后构建首帧并开始写。
    private func readyLocked() {
        EquilLog.debug("ready keepAlive=\(keepAlive)")

        // auto-unpair 让位：解绑请求写出前复查队列，有命令则放弃解绑、复用连接。
        if let pending = baseCmd as? CmdUnPair, pending.fromAutoUnpair, pumpQueuePending?() == true {
            pending.yieldedToQueue = true
            pending.resolvedResult = .notFound
            EquilLog.info("auto-unpair yielded at ready() — command queued, keeping binding")
            baseCmd = nil
            return
        }

        if let cmd = baseCmd {
            equilResponse = cmd.getEquilResponse()
            indexData = 0
            isWriting = false
            writeDataLocked()
        } else if keepAlive {
            EquilLog.debug("ready: no command, keepAlive mode")
            closeBleAutoLocked()
        } else {
            EquilLog.debug("ready: no command, disconnecting soon")
            closeBleAutoTimer.cancel()
            closeBleAutoTimer.schedule(500) { [weak self] in self?.disconnect() }
        }
    }

    /// 对照 `EquilBLE.nextCmd2`：复用会话发下一段。
    private func nextCmdLocked() {
        guard let cmd = baseCmd else { return }
        equilResponse = cmd.getNextEquilResponse()
        guard let resp = equilResponse, !resp.send.isEmpty else {
            EquilLog.debug("nextCmd: empty response")
            return
        }
        indexData = 0
        isWriting = false
        writeDataLocked()
    }

    /// 对照 `EquilBLE.writeData`：逐帧写出，全部写完启动 confirm 停滞监视。
    private func writeDataLocked() {
        guard !isWriting else { return }
        guard let resp = equilResponse else { return }
        let diff = nowMs() - resp.cmdCreateTime
        guard diff < EquilConst.cmdTimeOut else {
            EquilLog.debug("writeData: command timed out diff=\(diff)")
            return
        }
        if indexData < resp.send.count {
            isWriting = true
            let data = resp.send[indexData]
            EquilLog.debug("writeData index=\(indexData)/\(resp.send.count)")
            writeLocked(data)
            indexData += 1
        } else {
            scheduleConfirmWatchLocked()
        }
    }

    private func writeLocked(_ bytes: [UInt8]) {
        guard let transport = transport, transport.isConnected else {
            EquilLog.debug("write: link down, disconnecting")
            disconnectLocked()
            return
        }
        transport.write(bytes)
        writeTimeoutTimer.cancel()
        writeTimeoutTimer.schedule(EquilConst.bleWriteTimeoutMs) { [weak self] in
            self?.onWriteTimeout()
        }
    }

    // MARK: - 收帧

    /// 对照 `EquilBLE.decode`：单包解析失败只丢包，不中断链路。
    private func decodeLocked(_ buffer: [UInt8]) {
        lastRxTime = nowMs()
        guard let cmd = baseCmd else { return }
        if let resp = cmd.decodeEquilPacket(buffer) {
            writeConfLocked(resp)
        } else {
            scheduleConfirmWatchLocked()
        }
    }

    private func writeConfLocked(_ resp: EquilResponse?) {
        equilResponse = resp
        indexData = 0
        writeDataLocked()
    }

    // MARK: - 超时

    private func onWriteTimeout() {
        lock.lock(); defer { lock.unlock() }
        consecutiveWriteTimeoutCount += 1
        if consecutiveWriteTimeoutCount >= 3 {
            EquilLog.warn("BLE write timeout x\(consecutiveWriteTimeoutCount), forcing disconnect")
            consecutiveWriteTimeoutCount = 0
            baseCmd?.resolvedResult = .connectError
            disconnectLocked()
        } else {
            EquilLog.warn("BLE write timeout, retry (\(consecutiveWriteTimeoutCount)/3)")
            isWriting = false
            writeDataLocked()
        }
    }

    private func onConnectTimeout() {
        lock.lock(); defer { lock.unlock() }
        stopScan()
        EquilLog.debug("connect timeout")
        baseCmd?.resolvedResult = .connectError
        disconnectLocked()
    }

    /// 对照 `EquilBLE.scheduleConfirmWatch`。
    private func scheduleConfirmWatchLocked() {
        guard let cmd = baseCmd, cmd.config, !cmd.cmdStatus, !cmd.isEnd else { return }
        confirmWatchTimer.cancel()
        confirmWatchTimer.schedule(EquilConst.confirmWatchMs) { [weak self] in
            self?.onConfirmWatch()
        }
        confirmWatchScheduledAt = nowMs()
    }

    /// 对照 `EquilBLE.CONFIRM_WATCH_WHAT`：泵对 confirm 不重发，停滞时重写触发重应答。
    private func onConfirmWatch() {
        lock.lock(); defer { lock.unlock() }
        guard let cmd = baseCmd, isConnected, cmd.config, !cmd.cmdStatus, !cmd.isEnd else { return }
        guard confirmRewriteCount < EquilConst.confirmMaxRewrite else {
            EquilLog.warn("confirmWatch: still stalled after \(confirmRewriteCount) rewrites, giving up")
            return
        }
        if lastRxTime >= confirmWatchScheduledAt {
            // 窗口内有收帧活动，推迟监视。
            scheduleConfirmWatchLocked()
        } else {
            confirmRewriteCount += 1
            EquilLog.warn("confirmWatch: rewriting confirm (\(confirmRewriteCount)/\(EquilConst.confirmMaxRewrite))")
            indexData = 0
            isWriting = false
            writeDataLocked()
            scheduleConfirmWatchLocked()
        }
    }

    // MARK: - 连接管理

    /// 对照 `EquilBLE.connectEquil`：先停周期扫描（连接期间泵不广播），延迟后建连。
    private func connectEquilLocked() {
        stopPeriodicScanOnly()
        periodicScanTimer.cancel()
        connecting = true
        connectDelayTimer.schedule(EquilConst.bleConnectDelay) { [weak self] in
            self?.transport?.connect()
        }
    }

    /// 对照 `EquilBLE.findEquil`：扫描匹配。
    private func findEquilLocked() {
        guard !isConnected else { return }
        transport?.startScan()
        scanTimeoutTimer.cancel()
        scanTimeoutTimer.schedule(EquilConst.bleScanTimeout) { [weak self] in
            self?.stopScan()
        }
    }

    private func stopScan() {
        scanTimeoutTimer.cancel()
        transport?.stopScan()
    }

    /// 断开连接。对照 `EquilBLE.disconnect`。
    public func disconnect() {
        lock.lock(); defer { lock.unlock() }
        disconnectLocked()
    }

    private func disconnectLocked() {
        writeTimeoutTimer.cancel()
        writeContinueTimer.cancel()
        // 有界等待当前写入完成，避免在途数据被丢弃后写入陈旧帧。
        var waitCount = 0
        while isWriting && waitCount < 50 {
            EquilLog.debug("disconnect: waiting for BLE write to finish")
            Thread.sleep(forTimeInterval: 0.1)
            waitCount += 1
        }
        if isWriting { isWriting = false }

        closeBleAutoTimer.cancel()
        connectTimeoutTimer.cancel()
        connectDelayTimer.cancel()
        periodicScanTimer.cancel()
        periodicScanTimeoutTimer.cancel()
        preConnectTimer.cancel()
        scanTimeoutTimer.cancel()
        confirmWatchTimer.cancel()
        stopPeriodicScanOnly()
        stopScan()
        schedulePeriodicScanSoon()

        keepAlive = false
        isConnected = false
        isGattReady = false
        isDeviceDiscoverable = false
        directConnectFailed = false
        connecting = false
        sessionValid = false

        // 断开前保存会话，供重连复用（泵未解配前会话仍有效）。
        if sessionRunPwd == nil {
            sessionRunCode = preCmd?.runCode ?? baseCmd?.runCode
            sessionRunPwd = preCmd?.runPwd ?? baseCmd?.runPwd
            sessionReqIndex = EquilCounters.reqIndex
            sessionRspIndex = EquilCounters.rspIndex
        }
        baseCmd = nil
        preCmd = nil
        equilResponse = nil
        indexData = 0
        EquilCounters.reqIndex = 0
        EquilCounters.rspIndex = -1
        EquilOfficialSession.lastPumpToken = 0

        EquilLog.debug("closing GATT connection")
        transport?.disconnect()
        onStatusChange?(.disconnected)
    }

    private func closeBleAutoLocked() {
        closeBleAutoTimer.cancel()
        closeBleAutoTimer.schedule(EquilConst.bleKeepAlive) { [weak self] in self?.disconnect() }
    }

    /// 预连接：保持连接以便后续命令直接复用。
    public func preConnect(delayMs: Int64) {
        preConnectTimer.cancel()
        preConnectTimer.schedule(delayMs) { [weak self] in
            guard let self = self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard !self.isConnected && !self.connecting else { return }
            self.keepAlive = true
            self.findEquilLocked()
        }
    }

    /// 泵状态刷新扫描（电池/药量），对照 `EquilBLE.equilStatus`。
    public func scanForPump() {
        lock.lock(); defer { lock.unlock() }
        guard !isConnected, baseCmd == nil else { return }
        autoScan = false
        findEquilLocked()
    }

    // MARK: - 周期扫描

    public func startPeriodicScanning() {
        startPeriodicScan()
    }

    private func startPeriodicScan() {
        periodicScanTimeoutTimer.cancel()
        transport?.startScan()
        periodicScanTimeoutTimer.schedule(EquilConst.bleScanTimeout) { [weak self] in
            guard let self = self else { return }
            self.isDeviceDiscoverable = false
            self.onStatusChange?(.disconnected)
            self.schedulePeriodicScan()
        }
    }

    private func schedulePeriodicScan() {
        guard !periodicScanTimer.isScheduled else { return }
        let interval = (isBatteryCatchingUp?() == true)
            ? EquilConst.bleScanIntervalFast
            : EquilConst.bleScanInterval
        periodicScanTimer.schedule(interval) { [weak self] in self?.startPeriodicScan() }
    }

    /// 断连后快速扫描（泵在 GATT 连接期间不广播）。
    private func schedulePeriodicScanSoon() {
        periodicScanTimer.cancel()
        periodicScanTimer.schedule(1000) { [weak self] in self?.startPeriodicScan() }
    }

    private func stopPeriodicScanOnly() {
        periodicScanTimeoutTimer.cancel()
        transport?.stopScan()
    }

    // MARK: - EquilTransportDelegate

    public func transportDidDiscover(advertisement: [UInt8], rssi: Int) {
        lock.lock(); defer { lock.unlock() }
        isDeviceDiscoverable = true
        onStatusChange?(.connected)
        onAdvertisement?(advertisement, autoScan)
        stopScan()
        if baseCmd != nil {
            baseCmd?.resolvedResult = .connectError
            connectEquilLocked()
        } else {
            EquilLog.debug("discovered pump but no pending command, skipping connect")
        }
    }

    public func transportDidConnect() {
        lock.lock(); defer { lock.unlock() }
        isConnected = true
        isGattReady = false
        connecting = false
        consecutiveConnectFailureCount = 0
        connectTimeoutTimer.cancel()
        onStatusChange?(.connected)
        if let cmd = baseCmd { cmd.resolvedResult = .failure }
    }

    public func transportDidDiscoverServices(hasTargetService: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard hasTargetService else {
            EquilLog.warn("target service not found, forcing disconnect")
            baseCmd?.resolvedResult = .connectError
            disconnectLocked()
            return
        }
        if transport?.skipCccSubscription == true {
            EquilLog.info("skip CCC subscription (control client profile)")
            isGattReady = true
            readyLocked()
        } else {
            transport?.setNotify(true)
        }
    }

    public func transportIsReady() {
        lock.lock(); defer { lock.unlock() }
        isGattReady = true
        readyLocked()
    }

    public func transportDidWrite() {
        lock.lock(); defer { lock.unlock() }
        writeTimeoutTimer.cancel()
        isWriting = false
        consecutiveWriteTimeoutCount = 0
        // 帧间最小间隔，防止背靠背写出被泵静默丢弃。
        writeContinueTimer.schedule(EquilConst.bleWriteTimeOut) { [weak self] in
            guard let self = self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.writeDataLocked()
        }
    }

    public func transportDidReceive(_ data: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        decodeLocked(data)
    }

    public func transportDidDisconnect(error: EquilTransportError?) {
        lock.lock(); defer { lock.unlock() }
        if !isConnected && baseCmd == nil && !connecting { return }
        EquilLog.info("transport disconnected error=\(String(describing: error))")
        isWriting = false
        equilResponse = nil
        indexData = 0
        writeTimeoutTimer.cancel()
        isGattReady = false
        sessionValid = false
        EquilOfficialSession.lastPumpToken = 0
        baseCmd?.resolvedResult = .connectError
        disconnectLocked()
    }

    public func transportDidUpdateMtu(_ mtu: Int) {
        lock.lock(); defer { lock.unlock() }
        mtuSize = mtu
        EquilLog.debug("MTU updated to \(mtu)")
    }

    // MARK: - 工具

    private func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}