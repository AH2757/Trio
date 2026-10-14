import Combine
import EquilPumpKit
import LoopKit
import LoopKitUI
import SwiftUI
import UIKit

/// 向导/设置流程的屏幕标识。
enum EquilUIScreen {
    case welcomeScreen
    case pumpInfoScreen
    case pairingScreen
    case reservoirChangeScreen
    case settingsScreen
    case insulinTypeScreen
    case manualTempBasalScreen
}

/// `EquilPumpKit` 的界面协调器，对照 MedtrumKit `MedtrumKitUICoordinator`。
///
/// 向导流程（对照 Equil 的"用完即走"架构，无贴片寿命概念）：
/// 欢迎 → 泵信息（泵号/密码/胰岛素类型）→ 配对校验 → 更换储药器（推杆定位）→ 完成。
/// 已配置的泵进入则直接展示设置页。
class EquilKitUICoordinator: UINavigationController, PumpManagerOnboarding, CompletionNotifying,
    UINavigationControllerDelegate
{
    private let colorPalette: LoopUIColorPalette
    private var pumpManager: EquilPumpManager?
    private var allowedInsulinTypes: [InsulinType]
    private var allowDebugFeatures: Bool

    var pumpManagerOnboardingDelegate: PumpManagerOnboardingDelegate?
    var completionDelegate: CompletionDelegate?

    var screenStack = [EquilUIScreen]()
    var currentScreen: EquilUIScreen { screenStack.last! }

    init(
        pumpManager: EquilPumpManager? = nil,
        colorPalette: LoopUIColorPalette,
        pumpManagerSettings: PumpManagerSetupSettings? = nil,
        allowDebugFeatures: Bool,
        allowedInsulinTypes: [InsulinType] = []
    ) {
        if let pumpManager = pumpManager {
            self.pumpManager = pumpManager
        } else if let settings = pumpManagerSettings {
            let entries = EquilPumpManager.hourlyBasalEntries(from: settings.basalSchedule.items)
            self.pumpManager = EquilPumpManager(state: EquilPumpState(basalSchedule: entries))
        } else {
            self.pumpManager = EquilPumpManager(state: EquilPumpState())
        }

        self.colorPalette = colorPalette
        self.allowDebugFeatures = allowDebugFeatures
        self.allowedInsulinTypes = allowedInsulinTypes
        super.init(navigationBarClass: UINavigationBar.self, toolbarClass: UIToolbar.self)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationBar.prefersLargeTitles = true

        if screenStack.isEmpty {
            screenStack = getInitialScreens()
            let viewControllers = screenStack.map {
                let viewController = viewControllerForScreen($0)
                viewController.isModalInPresentation = false
                return viewController
            }
            setViewControllers(viewControllers, animated: false)
        }
    }

    override func viewDidDisappear(_: Bool) {
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func getInitialScreens() -> [EquilUIScreen] {
        guard let pumpManager = pumpManager else {
            return [.settingsScreen]
        }
        if !pumpManager.isOnboarded {
            return [.welcomeScreen]
        }
        return [.settingsScreen]
    }

    private func viewControllerForScreen(_ screen: EquilUIScreen) -> UIViewController {
        switch screen {
        case .welcomeScreen:
            return hostingController(
                rootView: EquilWelcomeView(nextStep: { [weak self] in self?.navigateTo(.pumpInfoScreen) }),
                title: String(localized: "Welcome", comment: "welcome header")
            )

        case .pumpInfoScreen:
            let viewModel = EquilPumpInfoViewModel(
                pumpManager,
                allowedInsulinTypes: allowedInsulinTypes,
                nextStep: { [weak self] in self?.navigateTo(.pairingScreen) }
            )
            return hostingController(
                rootView: EquilPumpInfoView(viewModel: viewModel),
                title: String(localized: "Pump Info", comment: "Pump info header")
            )

        case .pairingScreen:
            let viewModel = EquilPairingViewModel(
                pumpManager,
                nextStep: { [weak self] in
                    guard let self = self, let pumpManager = self.pumpManager else { return }
                    if let delegate = self.pumpManagerOnboardingDelegate {
                        delegate.pumpManagerOnboarding(didCreatePumpManager: pumpManager)
                    }
                    self.navigateTo(.reservoirChangeScreen)
                }
            )
            return hostingController(
                rootView: EquilPairingView(viewModel: viewModel)
                    .onAppear { UIApplication.shared.isIdleTimerDisabled = true },
                title: String(localized: "Pairing", comment: "Pairing header")
            )

        case .reservoirChangeScreen:
            let viewModel = EquilReservoirChangeViewModel(
                pumpManager,
                onDone: { [weak self] in self?.finishOnboarding() }
            )
            return hostingController(
                rootView: EquilReservoirChangeView(viewModel: viewModel)
                    .onAppear { UIApplication.shared.isIdleTimerDisabled = true },
                title: String(localized: "Change Reservoir", comment: "Reservoir change header")
            )

        case .settingsScreen:
            let viewModel = EquilKitSettingsViewModel(
                pumpManager,
                toManualTempBasal: { [weak self] in self?.navigateTo(.manualTempBasalScreen) },
                toInsulinType: { [weak self] in self?.navigateTo(.insulinTypeScreen) },
                pumpRemoval: { [weak self] in self?.pumpRemoval() }
            )
            return hostingController(
                rootView: EquilKitSettingsView(viewModel: viewModel),
                title: String(localized: "Equil Pump", comment: "Equil settings header")
            )

        case .insulinTypeScreen:
            let initial = pumpManager?.state.insulinType ?? allowedInsulinTypes.first ?? .novolog
            let view = EquilInsulinTypeView(
                initialValue: initial,
                supportedInsulinTypes: allowedInsulinTypes,
                didConfirm: { [weak self] insulinType in
                    guard let self = self else { return }
                    self.pumpManager?.state.insulinType = insulinType
                    self.pumpManager?.notifyStateDidChange()
                    self.screenStack.removeLast()
                    self.popViewController(animated: true)
                }
            )
            return hostingController(
                rootView: view,
                title: String(localized: "Select insulin type", comment: "Title for insulin type")
            )

        case .manualTempBasalScreen:
            let viewModel = EquilManualTempBasalViewModel(
                pumpManager: pumpManager,
                goBack: { [weak self] in
                    guard let self = self else { return }
                    self.screenStack.removeLast()
                    self.popViewController(animated: true)
                }
            )
            return hostingController(
                rootView: EquilManualTempBasalView(viewModel: viewModel),
                title: String(localized: "Manual Temp Basal", comment: "header manual temp basal")
            )
        }
    }

    private func hostingController<Content: View>(
        rootView: Content,
        title: String? = nil,
        largeTitleDisplayMode: UINavigationItem.LargeTitleDisplayMode = .automatic
    ) -> DismissibleHostingController<some View> {
        let rootView = rootView
            .environment(\.appName, Bundle.main.bundleDisplayName)
        let hostedView = DismissibleHostingController(content: rootView, colorPalette: colorPalette)
        hostedView.navigationItem.title = title
        hostedView.navigationItem.largeTitleDisplayMode = largeTitleDisplayMode
        return hostedView
    }

    // MARK: - 完成与移除

    private func finishOnboarding() {
        guard let pumpManager = pumpManager else { return }

        pumpManager.state.isOnboarded = true
        pumpManager.endWizard()
        pumpManager.notifyStateDidChange()

        if let delegate = pumpManagerOnboardingDelegate {
            delegate.pumpManagerOnboarding(didOnboardPumpManager: pumpManager)
        }

        resetNavigationTo([.settingsScreen])
    }

    private func pumpRemoval() {
        guard let pumpManager = pumpManager, let completionDelegate = completionDelegate else {
            return
        }

        pumpManager.prepareForDeactivation { _ in
            pumpManager.notifyDelegateOfDeactivation {
                DispatchQueue.main.async {
                    self.pumpManager = nil
                    completionDelegate.completionNotifyingDidComplete(self)
                }
            }
        }
    }
}

extension EquilKitUICoordinator {
    func navigateTo(_ screen: EquilUIScreen) {
        screenStack.append(screen)
        let viewController = viewControllerForScreen(screen)
        viewController.isModalInPresentation = false
        pushViewController(viewController, animated: true)
        viewController.view.layoutSubviews()
    }

    func resetNavigationTo(_ screens: [EquilUIScreen]) {
        screenStack = screens
        let viewControllers = screenStack.map {
            let viewController = viewControllerForScreen($0)
            viewController.isModalInPresentation = false
            viewController.view.layoutSubviews()
            return viewController
        }
        setViewControllers(viewControllers, animated: true)
    }
}