import EquilPumpKit
import LoopKit
import LoopKitUI
import SwiftUI

/// `EquilPumpManager` 的界面一致性（`PumpManagerUI`），对照 MedtrumKit 的 `MedtrumPumpManager+UI`。
///
/// 提供向导入口、设置入口、HUD Provider 与状态高亮/徽标。
/// 与 MedtrumKit 的差异：Equil 无"贴片寿命"，故 `pumpLifecycleProgress` 恒为 nil；
/// 状态高亮关注未初始化、低电量、低药量、信号丢失与暂停。
extension EquilPumpManager: PumpManagerUI {

    // MARK: - 向导

    public static func setupViewController(
        initialSettings settings: PumpManagerSetupSettings,
        bluetoothProvider _: BluetoothProvider,
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool,
        prefersToSkipUserInteraction _: Bool,
        allowedInsulinTypes: [InsulinType]
    ) -> SetupUIResult<PumpManagerViewController, PumpManagerUI> {
        let vc = EquilKitUICoordinator(
            colorPalette: colorPalette,
            pumpManagerSettings: settings,
            allowDebugFeatures: allowDebugFeatures,
            allowedInsulinTypes: allowedInsulinTypes
        )
        return .userInteractionRequired(vc)
    }

    // MARK: - 设置

    public func settingsViewController(
        bluetoothProvider _: BluetoothProvider,
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool,
        allowedInsulinTypes: [InsulinType]
    ) -> PumpManagerViewController {
        EquilKitUICoordinator(
            pumpManager: self,
            colorPalette: colorPalette,
            allowDebugFeatures: allowDebugFeatures,
            allowedInsulinTypes: allowedInsulinTypes
        )
    }

    public func deliveryUncertaintyRecoveryViewController(
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool
    ) -> (UIViewController & CompletionNotifying) {
        EquilKitUICoordinator(
            pumpManager: self,
            colorPalette: colorPalette,
            allowDebugFeatures: allowDebugFeatures
        )
    }

    // MARK: - HUD

    public func hudProvider(
        bluetoothProvider: BluetoothProvider,
        colorPalette: LoopUIColorPalette,
        allowedInsulinTypes: [InsulinType]
    ) -> HUDProvider? {
        EquilHUDProvider(
            pumpManager: self,
            bluetoothProvider: bluetoothProvider,
            colorPalette: colorPalette,
            allowedInsulinTypes: allowedInsulinTypes
        )
    }

    public static func createHUDView(rawValue: HUDProvider.HUDViewRawState) -> BaseHUDView? {
        EquilHUDProvider.createHUDView(rawValue: rawValue)
    }

    // MARK: - 设备图像

    public static var onboardingImage: UIImage? {
        UIImage(systemName: "drop.fill")
    }

    public var smallImage: UIImage? {
        UIImage(systemName: "drop.fill")
    }

    // MARK: - 状态高亮

    public var pumpStatusHighlight: DeviceStatusHighlight? {
        if !state.isPumpInitialized {
            return PumpStatusHighlight(
                localizedMessage: String(
                    localized: "Pump not initialized",
                    comment: "Status highlight when the Equil pump has not completed reservoir change"
                ),
                imageName: "exclamationmark.circle.fill",
                state: .critical
            )
        }

        if state.reservoirUnits <= 0 {
            return PumpStatusHighlight(
                localizedMessage: String(
                    localized: "No Insulin",
                    comment: "Status highlight that the pump is out of insulin"
                ),
                imageName: "exclamationmark.circle.fill",
                state: .critical
            )
        }

        if state.batteryPercent > 0, state.batteryPercent <= EquilPumpManager.lowBatteryThreshold {
            return PumpStatusHighlight(
                localizedMessage: String(
                    localized: "Low Battery",
                    comment: "Status highlight that the pump battery is low"
                ),
                imageName: "exclamationmark.circle.fill",
                state: .warning
            )
        }

        if state.basalDose.type == .suspend {
            return PumpStatusHighlight(
                localizedMessage: String(
                    localized: "Insulin Suspended",
                    comment: "Status highlight that insulin delivery was suspended"
                ),
                imageName: "pause.circle.fill",
                state: .warning
            )
        }

        if Date.now.timeIntervalSince(state.lastCommunication ?? .distantPast) > .minutes(15) {
            return PumpStatusHighlight(
                localizedMessage: String(
                    localized: "Signal Loss",
                    comment: "Status highlight when communications with the pump haven't happened recently"
                ),
                imageName: "exclamationmark.circle.fill",
                state: .critical
            )
        }

        return nil
    }

    /// Equil 无贴片寿命，不使用生命周期进度条。
    public var pumpLifecycleProgress: DeviceLifecycleProgress? { nil }

    /// Equil 不做泵端时间漂移标定，不使用状态徽标。
    public var pumpStatusBadge: DeviceStatusBadge? { nil }
}