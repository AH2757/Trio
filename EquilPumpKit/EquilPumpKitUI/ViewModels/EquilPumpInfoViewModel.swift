import EquilPumpKit
import LoopKit
import LoopKitUI

/// 泵信息（泵号 / 配对密码 / 胰岛素类型）录入的视图模型。
///
/// 对照 MedtrumKit `PumpBaseSettingsViewModel`：向导在此写入配对所需字段。
/// 与 Medtrum 的差异：Equil 需要用户输入的 6 位数字配对密码，且泵号是 6 位 hex。
class EquilPumpInfoViewModel: ObservableObject {

    /// 泵号（6 位 hex，如 "D02563"）。
    @Published var serialNumber: String
    /// 用户输入的 6 位数字配对密码。
    @Published var password: String
    @Published var insulinType: InsulinType?
    @Published var errorMessage: String = ""

    let allowedInsulinTypes: [InsulinType]

    private let pumpManager: EquilPumpManager?
    private let nextStep: () -> Void

    init(
        _ pumpManager: EquilPumpManager?,
        allowedInsulinTypes: [InsulinType],
        nextStep: @escaping () -> Void
    ) {
        self.pumpManager = pumpManager
        self.allowedInsulinTypes = allowedInsulinTypes
        self.nextStep = nextStep
        self.serialNumber = pumpManager?.state.serialNumber ?? ""
        self.password = pumpManager?.state.password ?? ""
        self.insulinType = pumpManager?.state.insulinType ?? allowedInsulinTypes.first
    }

    /// 泵号：6 位十六进制。
    var isSerialNumberValid: Bool {
        serialNumber.count == 6 && serialNumber.allSatisfy { $0.isHexDigit }
    }

    /// 配对密码：6 位数字。
    var isPasswordValid: Bool {
        password.count == 6 && password.allSatisfy { $0.isNumber }
    }

    var canContinue: Bool {
        isSerialNumberValid && isPasswordValid && insulinType != nil
    }

    func saveAndContinue() {
        guard let pumpManager = pumpManager else {
            nextStep()
            return
        }

        guard isSerialNumberValid else {
            errorMessage = String(localized: "Serial number must be 6 hex characters.", comment: "Serial number validation error")
            return
        }
        guard isPasswordValid else {
            errorMessage = String(localized: "Pairing password must be 6 digits.", comment: "Pairing password validation error")
            return
        }
        guard let insulinType = insulinType else {
            errorMessage = String(localized: "Select an insulin type.", comment: "Insulin type validation error")
            return
        }

        let serial = serialNumber.uppercased()

        // 泵号变化 → 清掉旧的绑定凭据与外设标识，强制重新配对（对照 AAPS 换泵行为）。
        if pumpManager.state.serialNumber.uppercased() != serial {
            pumpManager.state.deviceToken = ""
            pumpManager.state.sessionPassword = ""
            pumpManager.state.peripheralIdentifier = nil
            pumpManager.state.firmwareVersion = nil
            pumpManager.state.isPumpInitialized = false
        }

        pumpManager.state.serialNumber = serial
        pumpManager.state.deviceName = "Equil - \(serial)"
        pumpManager.state.password = password
        pumpManager.state.insulinType = insulinType
        pumpManager.notifyStateDidChange()

        errorMessage = ""
        nextStep()
    }
}