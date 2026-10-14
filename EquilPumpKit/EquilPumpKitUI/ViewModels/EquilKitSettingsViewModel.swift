import EquilKit
import EquilPumpKit
import LoopKit
import LoopKitUI

/// 泵设置页的视图模型，对照 MedtrumKit `MedtrumKitSettingsViewModel`。
///
/// 与 Medtrum 的差异：Equil 无贴片寿命/泵端时间漂移，故不展示生命周期进度与时间同步告警；
/// 暂停为无限期（需手动恢复），因此没有暂停时长选择器。
class EquilKitSettingsViewModel: ObservableObject, PumpManagerStatusObserver {
    private let processQueue = DispatchQueue(label: "com.equilpumpkit.settingsViewModel")

    @Published var isPumpInitialized = false
    @Published var isConnected = false
    @Published var serialNumber = ""
    @Published var firmwareVersion: String?
    @Published var reservoirLevel: Double = 0
    @Published var maxReservoirLevel: Double = 200
    @Published var batteryPercent: Double?
    @Published var runMode: RunMode = .stop
    @Published var basalType: DoseType = .basal
    @Published var basalRate: String = ""
    @Published var insulinType: InsulinType = .novolog
    @Published var lastSync = Date.distantPast
    @Published var lastCommunication: Date?
    @Published var isBolusing = false

    @Published var isUpdatingPumpState = false
    @Published var isUpdatingSuspend = false
    @Published var isUpdatingTempBasal = false
    @Published var showingDeleteConfirmation = false
    @Published var error: String?

    let toManualTempBasal: () -> Void
    let toInsulinType: () -> Void
    let pumpRemovalAction: () -> Void

    private let pumpManager: EquilPumpManager?

    let reservoirVolumeFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.roundingMode = .floor
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    let basalRateFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.minimumIntegerDigits = 1
        return formatter
    }()

    let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()

    let timeRemainingFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .short
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    init(
        _ pumpManager: EquilPumpManager?,
        toManualTempBasal: @escaping () -> Void,
        toInsulinType: @escaping () -> Void,
        pumpRemoval: @escaping () -> Void
    ) {
        self.pumpManager = pumpManager
        self.toManualTempBasal = toManualTempBasal
        self.toInsulinType = toInsulinType
        self.pumpRemovalAction = pumpRemoval

        guard let pumpManager = pumpManager else { return }

        maxReservoirLevel = pumpManager.pumpReservoirCapacity
        isConnected = pumpManager.isConnected
        updateState(pumpManager.state)
        pumpManager.addStatusObserver(self, queue: processQueue)
    }

    deinit {
        pumpManager?.removeStatusObserver(self)
    }

    // MARK: - 展示派生

    func reservoirText(for units: Double) -> String {
        reservoirVolumeFormatter.string(from: units as NSNumber) ?? ""
    }

    var runModeText: String {
        switch runMode {
        case .run: return String(localized: "Running", comment: "Pump run mode running")
        case .suspend: return String(localized: "Suspended", comment: "Pump run mode suspended")
        case .stop: return String(localized: "Stopped", comment: "Pump run mode stopped")
        }
    }

    var isSuspended: Bool { basalType == .suspend }

    var tempBasalRemaining: String? {
        guard basalType == .tempBasal, let pumpManager = pumpManager else { return nil }
        let remaining = pumpManager.state.basalDose.estimatedEndDate.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        return timeRemainingFormatter.string(from: remaining)
    }

    var batteryText: String {
        guard let batteryPercent = batteryPercent, batteryPercent > 0 else { return "–" }
        return String(format: "%.0f%%", batteryPercent)
    }

    // MARK: - 操作

    func syncData() {
        guard let pumpManager = pumpManager else { return }
        isUpdatingPumpState = true
        pumpManager.syncPumpData { _ in
            DispatchQueue.main.async {
                self.isUpdatingPumpState = false
            }
        }
    }

    func stopTempBasal() {
        guard let pumpManager = pumpManager else { return }
        isUpdatingTempBasal = true
        pumpManager.enactTempBasal(unitsPerHour: 0, for: 0) { error in
            DispatchQueue.main.async {
                self.isUpdatingTempBasal = false
                if let error = error {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func suspendResumeButtonPressed() {
        guard let pumpManager = pumpManager else { return }

        isUpdatingSuspend = true
        let completion: (Error?) -> Void = { error in
            DispatchQueue.main.async {
                self.isUpdatingSuspend = false
                if let error = error {
                    self.error = error.localizedDescription
                }
            }
        }

        if isSuspended {
            pumpManager.resumeDelivery(completion: completion)
        } else {
            pumpManager.suspendDelivery(completion: completion)
        }
    }

    func didChangeInsulinType(_ newType: InsulinType?) {
        guard let newType = newType, let pumpManager = pumpManager else { return }
        pumpManager.state.insulinType = newType
        pumpManager.notifyStateDidChange()
        insulinType = newType
    }

    func stopUsingEquil() {
        guard let pumpManager = pumpManager else {
            pumpRemovalAction()
            return
        }

        pumpManager.prepareForDeactivation { _ in
            DispatchQueue.main.async {
                self.pumpRemovalAction()
            }
        }
    }

    // MARK: - 状态刷新

    func pumpManager(_ pumpManager: PumpManager, didUpdate _: PumpManagerStatus, oldStatus _: PumpManagerStatus) {
        guard let pumpManager = pumpManager as? EquilPumpManager else { return }
        DispatchQueue.main.async {
            self.isConnected = pumpManager.isConnected
            self.updateState(pumpManager.state)
        }
    }

    private func updateState(_ state: EquilPumpState) {
        isPumpInitialized = state.isPumpInitialized
        serialNumber = state.serialNumber
        firmwareVersion = state.firmwareVersion
        reservoirLevel = state.reservoirUnits
        batteryPercent = state.batteryPercent > 0 ? state.batteryPercent : nil
        runMode = state.runMode
        basalType = state.basalDose.type
        basalRate = basalRateFormatter.string(
            from: (basalType == .tempBasal ? state.basalDose.value : state.currentBaseBasalRate) as NSNumber
        ) ?? ""
        lastSync = state.lastSync
        lastCommunication = state.lastCommunication
        isBolusing = state.bolusDose != nil

        if let insulinType = state.insulinType {
            self.insulinType = insulinType
        }
    }
}