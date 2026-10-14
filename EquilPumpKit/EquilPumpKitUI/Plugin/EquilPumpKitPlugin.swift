import EquilPumpKit
import LoopKitUI

/// EquilPumpKit 的 LoopKit UI 插件入口，对照 MedtrumKit `MedtrumKitPlugin`。
///
/// 说明：Trio 不使用 bundle 插件发现机制，而是把各 kit 静态链接后统一登记在
/// `Trio/Sources/APS/Devices/DeviceCatalog.swift`。因此接入 Trio 时需要在 `DeviceCatalog.pumps`
/// 增加一条 `EquilPumpManager.self` 的条目（详见 `docs/10-泵驱动层实现说明.md`）。
/// 本类保留 `PumpManagerUIPlugin` 实现，兼容仍走 bundle 插件的宿主。
class EquilPumpKitPlugin: NSObject, PumpManagerUIPlugin {
    public var pumpManagerType: PumpManagerUI.Type? {
        EquilPumpManager.self
    }

    public var cgmManagerType: CGMManagerUI.Type? {
        nil
    }

    override init() {
        super.init()
    }
}