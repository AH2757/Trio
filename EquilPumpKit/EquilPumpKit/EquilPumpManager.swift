import Foundation
import HealthKit
import LoopKit
import EquilKit

#if canImport(CoreBluetooth)
import CoreBluetooth
#endif

/// 微泰 Equil 泵的 LoopKit `PumpManager` 驱动，对照 MedtrumKit `MedtrumPumpManager`。
///
/// 三层结构：
/// - `EquilPumpState`：可持久化状态模型（含遥测、基础率表、剂量跟踪、报警）；
/// - `EquilCommandExecutor`：AAPS 那套"用完即走 + 单槽串行 + 重试自愈"的命令执行器；
/// - `EquilPumpManager`（本类）：把上面两层粘到 LoopKit 抽象接口上。
///
/// 本文件只放"核心"：协议属性、初始化、BLE 栈装配、状态通知与事件发射。
/// 同步逻辑在 `EquilPumpManager+Sync.swift`，剂量命令在 `EquilPumpManager+Commands.swift`。
///
/// 硬约束（来自 `docs/08-AAPS可借鉴逻辑清单.md` 与任务书任务 C）：
/// - 用完即走：业务命令前自动绑定、空闲 5 秒自动解绑断连，官方控制器可随时接管；
/// - 不写 CCC：全部 AES 命令 `preferNoCccSubscription = true`；
/// - 不 createBond：直接 GATT 连接；
/// - 绑定与输注独立：解绑后泵继续按本地基础率输注。
public class EquilPumpManager: PumpManager {

    public static let pluginIdentifier = "Equil"

    public let localizedTitle = "微泰 Equil 泵"
    public let managerIdentifier = "Equil"

    // MARK: - 状态

    public var state: EquilPumpState
    private var oldState: EquilPumpState

    public var rawState: PumpManager.RawStateValue { state.rawValue }
    public var isOnboarded: Bool { state.isOnboarded }

    public var debugDescription: String { state.debugDescription }

    // MARK: - 委托与观察者

    public let pumpDelegate = WeakSynchronizedDelegate<PumpManagerDelegate>()
    private let statusObservers = WeakSynchronizedSet<PumpManagerStatusObserver>()

    public var pumpManagerDelegate: PumpManagerDelegate? {
        get { pumpDelegate.delegate }
        set { pumpDelegate.delegate = newValue }
    }

    public var delegateQueue: DispatchQueue! {
        get { pumpDelegate.queue }
        set { pumpDelegate.queue = newValue }
    }

    // MARK: - BLE 栈

    let link: EquilLinkController
    let executor: EquilCommandExecutor

    #if canImport(CoreBluetooth)
    let transport: CoreBluetoothTransport
    #endif

    /// 命令/多命令序列的串行工作队列（不阻塞主线程；`BaseCmd.waitForCompletion` 会阻塞）。
    let workQueue = DispatchQueue(label: "com.equilpumpkit.manager", qos: .userInitiated)

    // MARK: - 瞬态（不持久化）

    private var mustProvideBLEHeartbeat = false
    private var lastHeartbeat: Date = .distantPast
    private static let heartbeatInterval: TimeInterval = .minutes(1)

    /// 闭环是否活跃（活跃期延长空闲解绑延迟，复用绑定）。由 Trio 侧设置。
    public var closedLoopActive = false

    /// 大剂量输注完成定时器（Equil 不回传进度，按估算时长收尾）。
    var bolusFinalizeWork: DispatchWorkItem?

    /// 低药量/低电量告警的边沿去重标记。
    var didAlertLowReservoir = false
    var didAlertLowBattery = false

    // MARK: - 阈值

    /// 低药量告警阈值（U）。
    public static let lowReservoirThreshold: Double = 10
    /// 低电量告警阈值（%）。
    public static let lowBatteryThreshold: Double = 20
    /// 数据新鲜窗口：小于此间隔的同步会被跳过。
    public static let loopSyncFreshnessInterval: TimeInterval = .minutes(4.5)

    // MARK: - 初始化

    public init(state: EquilPumpState) {
        self.state = state
        self.oldState = EquilPumpState(rawValue: state.rawValue)

        #if canImport(CoreBluetooth)
        let transport = CoreBluetoothTransport()
        self.transport = transport
        let link = EquilLinkController(transport: transport)
        #else
        let link = EquilLinkController()
        #endif
        self.link = link
        self.executor = EquilCommandExecutor(link: link, settings: state)

        configureLink()
    }

    public required convenience init?(rawState: RawStateValue) {
        self.init(state: EquilPumpState(rawValue: rawState))
    }

    private func configureLink() {
        link.onStatusChange = { [weak self] status in
            guard let self = self else { return }
            if status == .connected {
                self.state.lastCommunication = Date.now
            }
            self.notifyStateDidChange()
        }

        // 广播是"用完即走"架构下唯一无需绑定即可获取的遥测（电量/药量/历史游标/事件）。
        link.onAdvertisement = { [weak self] bytes, _ in
            self?.handleAdvertisement(bytes)
        }

        // auto-unpair 让位判定：命令执行器有在途命令时，解绑让位、复用连接。
        link.pumpQueuePending = { [weak self] in
            self?.executor.hasPendingCommand ?? false
        }

        // 电量追赶窗口：加快周期扫描。
        link.isBatteryCatchingUp = { [weak self] in
            guard let self = self else { return false }
            return Date.now.timeIntervalSince(self.state.lastCommunication ?? .distantPast) > .minutes(10)
        }

        #if canImport(CoreBluetooth)
        // 首次匹配/连接成功即持久化外设标识，后续直连免扫描。
        transport.onPeripheralIdentifier = { [weak self] uuid in
            self?.state.peripheralIdentifier = uuid
        }
        #endif

        executor.closedLoopActive = { [weak self] in self?.closedLoopActive ?? false }

        executor.onCommandFinished = { [weak self] _ in
            self?.state.lastCommunication = Date.now
        }
    }

    /// 启动周期扫描（电池/药量生命线）。Trio 激活驱动后调用。
    public func startPeriodicScanning() {
        link.startPeriodicScanning()
    }

    // MARK: - 能力与限值

    public static var onboardingMaximumBasalScheduleEntryCount: Int { 24 }

    /// 基础率步进 0.01 U/h；0 为合法计划基础率。上限 20 U/h（对照默认 maxBasal）。
    public static var onboardingSupportedBasalRates: [Double] {
        (0...2000).map { Double($0) / 100 }
    }

    /// 大剂量步进 0.05 U；0 不是合法大剂量。
    public static var onboardingSupportedBolusVolumes: [Double] {
        (1...600).map { Double($0) / 20 }
    }

    public static var onboardingSupportedMaximumBolusVolumes: [Double] {
        EquilPumpManager.onboardingSupportedBolusVolumes
    }

    public var supportedBasalRates: [Double] { EquilPumpManager.onboardingSupportedBasalRates }
    public var supportedBolusVolumes: [Double] { EquilPumpManager.onboardingSupportedBolusVolumes }
    public var supportedMaximumBolusVolumes: [Double] { EquilPumpManager.onboardingSupportedMaximumBolusVolumes }

    public var maximumBasalScheduleEntryCount: Int { EquilPumpManager.onboardingMaximumBasalScheduleEntryCount }

    /// 泵按小时段执行基础率，最小条目时长 1 小时。
    public var minimumBasalScheduleEntryDuration: TimeInterval { .hours(1) }

    public func roundToSupportedBasalRate(unitsPerHour: Double) -> Double {
        max(0, (unitsPerHour * 100).rounded(.down) / 100)
    }

    public func roundToSupportedBolusVolume(units: Double) -> Double {
        max(0, (units * 20).rounded(.down) / 20)
    }

    /// 基础率取整到 0.01（供 `UnfinalizedDose` 定稿剂量构造）。
    public static func roundBasalRate(_ rate: Double) -> Double {
        max(0, (rate * 100).rounded() / 100)
    }

    // MARK: - 设备与状态

    public var pumpRecordsBasalProfileStartEvents: Bool { false }

    /// 储药器容量 200 U。
    public var pumpReservoirCapacity: Double { 200 }

    public var lastSync: Date? { state.lastSync }

    /// GATT 是否已建立连接。用完即走架构下连接是瞬态的（空闲即解绑断连），
    /// 仅用于 UI 展示，不参与剂量前置判断。
    public var isConnected: Bool { link.isConnected }

    public var status: PumpManagerStatus { status(state) }

    private func status(_ state: EquilPumpState) -> PumpManagerStatus {
        PumpManagerStatus(
            timeZone: TimeZone.current,
            device: device(state),
            pumpBatteryChargeRemaining: state.batteryPercent > 0 ? state.batteryPercent / 100.0 : nil,
            basalDeliveryState: state.basalDeliveryState,
            bolusState: state.bolusDeliveryState,
            insulinType: state.insulinType
        )
    }

    private func device(_ state: EquilPumpState) -> HKDevice {
        HKDevice(
            name: state.deviceName.isEmpty ? "Equil" : state.deviceName,
            manufacturer: "Microtech",
            model: "Equil",
            hardwareVersion: nil,
            firmwareVersion: state.firmwareVersion,
            softwareVersion: nil,
            localIdentifier: state.peripheralIdentifier?.uuidString,
            udiDeviceIdentifier: nil
        )
    }

    public func addStatusObserver(_ observer: PumpManagerStatusObserver, queue: DispatchQueue) {
        statusObservers.insert(observer, queue: queue)
    }

    public func removeStatusObserver(_ observer: PumpManagerStatusObserver) {
        statusObservers.removeElement(observer)
    }

    // MARK: - 告警

    public func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier, completion: @escaping (Error?) -> Void) {
        // 泵端告警的清除由换药/复位流程完成，本驱动不回写泵，仅通知 LoopKit 停止展示。
        EquilLog.info("acknowledgeAlert \(alertIdentifier)")
        completion(nil)
    }

    public func getSoundBaseURL() -> URL? { nil }

    public func getSounds() -> [Alert.Sound] { [] }

    // MARK: - BLE 心跳

    public func setMustProvideBLEHeartbeat(_ mustProvideBLEHeartbeat: Bool) {
        self.mustProvideBLEHeartbeat = mustProvideBLEHeartbeat
    }

    /// 按需向 LoopKit 上报 BLE 心跳（供远端 CGM 场景唤醒 App）。
    func issueHeartbeatIfNeeded() {
        guard mustProvideBLEHeartbeat,
              Date.now.timeIntervalSince(lastHeartbeat) > Self.heartbeatInterval
        else { return }

        lastHeartbeat = Date.now
        EquilLog.info("Firing BLE heartbeat")
        pumpDelegate.notify { delegate in
            delegate?.pumpManagerBLEHeartbeatDidFire(self)
        }
    }

    // MARK: - 事件发射

    public func notifyStateDidChange() {
        DispatchQueue.main.async {
            let status = self.status(self.state)
            let oldStatus = self.status(self.oldState)

            self.pumpDelegate.notify { delegate in
                delegate?.pumpManagerDidUpdateState(self)
                delegate?.pumpManager(self, didUpdate: status, oldStatus: oldStatus)
            }

            self.statusObservers.forEach { observer in
                observer.pumpManager(self, didUpdate: status, oldStatus: oldStatus)
            }

            self.oldState = EquilPumpState(rawValue: self.state.rawValue)
        }
    }

    /// 发送泵事件。`replacePendingEvents` 时补入仍在途的大剂量/TBR，避免宿主历史丢失可变剂量。
    func emitPumpEvents(_ events: [NewPumpEvent], replacePendingEvents: Bool = true) {
        var events = events

        if replacePendingEvents {
            if let bolusDose = state.bolusDose, !events.contains(where: { $0.type == .bolus }) {
                events.append(NewPumpEvent.bolus(unfinalizedDose: bolusDose))
            }
            if !events.contains(where: { $0.type == .tempBasal }) {
                events.append(contentsOf: runningTempBasal())
            }
        }

        pumpDelegate.notify { delegate in
            guard let delegate = delegate else { return }
            delegate.pumpManager(
                self,
                hasNewPumpEvents: events,
                lastReconciliation: self.state.lastSync,
                replacePendingEvents: replacePendingEvents
            ) { error in
                if let error = error {
                    self.logDeviceCommunication("hasNewPumpEvents error: \(error)", type: .error)
                }
            }
        }
    }

    func emitReservoirLevel(at date: Date = Date.now) {
        pumpDelegate.notify { delegate in
            delegate?.pumpManager(self, didReadReservoirValue: self.state.reservoirUnits.rounded(toPlaces: 1), at: date) { result in
                if case let .failure(error) = result {
                    self.logDeviceCommunication("didReadReservoirValue error: \(error)", type: .error)
                }
            }
        }
    }

    func emitAlert(_ alert: EquilAlert) {
        pumpDelegate.notify { delegate in
            delegate?.issueAlert(alert.alert)
        }
    }

    func logDeviceCommunication(_ message: String, type: DeviceLogEntryType = .send) {
        let identifier = state.serialNumber
        pumpManagerDelegate?.deviceManager(
            self,
            logEventForDeviceIdentifier: identifier,
            type: type,
            message: message,
            completion: nil
        )
    }

    // MARK: - 剂量事件工具

    /// 当前 TBR（若有），以"仍在进行"的可变剂量回报。
    func runningTempBasal() -> [NewPumpEvent] {
        guard state.basalDose.type == .tempBasal else { return [] }
        return [NewPumpEvent.tempBasal(dose: state.basalDose.toDoseEntry(isMutable: true))]
    }

    /// 当前 TBR（若有），定稿为在 `endedAt` 停止。
    func finalizedTempBasal(endedAt: Date) -> [NewPumpEvent] {
        guard state.basalDose.type == .tempBasal else { return [] }
        return [NewPumpEvent.tempBasal(dose: state.basalDose.toDoseEntry(isMutable: false, endDate: endedAt))]
    }

    /// 按时间线性估算大剂量已输注量。
    func estimatedDelivered(for dose: UnfinalizedDose) -> Double {
        let elapsed = -dose.startDate.timeIntervalSinceNow
        let duration = max(dose.estimatedEndDate.timeIntervalSince(dose.startDate), .ulpOfOne)
        return roundToSupportedBolusVolume(units: min(elapsed / duration, 1) * dose.value)
    }

    // MARK: - 生命周期

    public func prepareForDeactivation(_ completion: @escaping (Error?) -> Void) {
        executor.unpairNow {
            self.notifyDelegateOfDeactivation { completion(nil) }
        }
    }

    deinit {
        bolusFinalizeWork?.cancel()
        EquilLog.info("EquilPumpManager deallocated")
    }
}