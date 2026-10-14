import EquilPumpKit
import LoopKit
import LoopKitUI
import SwiftUI
import UIKit

/// Equil HUD Provider，对照 MedtrumKit `MedtrumKitHUDProvider`。
///
/// 只提供一个储药器 HUD：展示剩余药量与最近同步时间，状态变化时刷新。
internal class EquilHUDProvider: NSObject, HUDProvider {
    private let processQueue = DispatchQueue(label: "com.equilpumpkit.hudProvider")
    private let pumpManager: EquilPumpManager

    private let bluetoothProvider: BluetoothProvider
    private let colorPalette: LoopUIColorPalette
    private let allowedInsulinTypes: [InsulinType]
    private var reservoirView: EquilReservoirView?

    var visible: Bool = true {
        didSet {
            if oldValue != visible, visible {
                hudDidAppear()
            }
        }
    }

    init(
        pumpManager: EquilPumpManager,
        bluetoothProvider: BluetoothProvider,
        colorPalette: LoopUIColorPalette,
        allowedInsulinTypes: [InsulinType]
    ) {
        self.pumpManager = pumpManager
        self.bluetoothProvider = bluetoothProvider
        self.colorPalette = colorPalette
        self.allowedInsulinTypes = allowedInsulinTypes
        super.init()

        pumpManager.addStatusObserver(self, queue: processQueue)
    }

    func createHUDView() -> BaseHUDView? {
        reservoirView = EquilReservoirView()
        updateReservoirView()
        return reservoirView
    }

    func didTapOnHUDView(_: BaseHUDView, allowDebugFeatures _: Bool) -> HUDTapAction? {
        nil
    }

    var hudViewRawState: HUDViewRawState {
        var rawValue: HUDProvider.HUDViewRawState = [:]
        rawValue["lastSync"] = pumpManager.state.lastSync
        rawValue["reservoir"] = pumpManager.state.reservoirUnits
        rawValue["maxReservoir"] = EquilReservoirView.maxReservoirUnits
        return rawValue
    }

    var managerIdentifier: String {
        pumpManager.managerIdentifier
    }

    static func createHUDView(rawValue: HUDProvider.HUDViewRawState) -> BaseHUDView? {
        guard let reservoir = rawValue["reservoir"] as? Double else {
            return nil
        }
        let lastSync = rawValue["lastSync"] as? Date
        let maxReservoir = rawValue["maxReservoir"] as? Double ?? EquilReservoirView.maxReservoirUnits

        let view = EquilReservoirView()
        view.update(level: reservoir, max: maxReservoir, at: lastSync)
        return view
    }

    private func hudDidAppear() {
        updateReservoirView()
        pumpManager.ensureCurrentPumpData { _ in
            self.updateReservoirView()
        }
    }

    private func updateReservoirView() {
        guard let reservoirView = reservoirView else { return }
        let level = pumpManager.state.reservoirUnits
        let lastSync = pumpManager.state.lastSync
        DispatchQueue.main.async {
            reservoirView.update(level: level, max: EquilReservoirView.maxReservoirUnits, at: lastSync)
        }
    }
}

extension EquilHUDProvider: PumpManagerStatusObserver {
    func pumpManager(_: PumpManager, didUpdate _: PumpManagerStatus, oldStatus _: PumpManagerStatus) {
        updateReservoirView()
    }
}