import Foundation
import EquilKit

/// 把 `EquilPumpState` 暴露成 `EquilKit` 命令层所需的设置存储。
///
/// 命令层只需要 `equilDevices` / `equilPassword` / `bolusRate`（`EquilSettingsStore`），
/// 驱动层额外需要广播名、用户配对密码与外设标识（`EquilPumpSettingsStore`）。
/// `CmdPair` 成功后会把设备标识与会话密码写回本存储，因此这三项直接映射到持久化状态。
extension EquilPumpState: EquilPumpSettingsStore {

    /// AAPS `equilDevices`（CmdPair 写回的设备标识，hex）。
    public var equilDevices: String {
        get { deviceToken }
        set { deviceToken = newValue }
    }

    /// AAPS `equilPassword`（CmdPair 写回的会话密码，hex）。
    public var equilPassword: String {
        get { sessionPassword }
        set { sessionPassword = newValue }
    }

    /// 广播名（如 "Equil - D02563"）。
    public var equilDeviceName: String { deviceName }

    /// 用户输入的 6 位数字配对密码。
    public var equilPairingPassword: String { password }

    /// Core Bluetooth 外设标识（iOS 无 MAC）。
    public var equilPeripheralIdentifier: String? { peripheralIdentifier?.uuidString }
}