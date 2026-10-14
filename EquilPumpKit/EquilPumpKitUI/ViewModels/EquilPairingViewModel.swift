import EquilKit
import EquilPumpKit
import LoopKit
import LoopKitUI

/// 配对校验页的视图模型。
///
/// 调用驱动层的 `pairAndVerify`：强制一次全新 `CmdPair` 并读回设备信息确认连通。
/// 与 MedtrumKit 的差异：Equil 无"贴片"，配对的是泵本体，成功后进入更换储药器流程。
class EquilPairingViewModel: ObservableObject {
    private let processQueue = DispatchQueue(label: "com.equilpumpkit.pairingViewModel")

    @Published var isPairing = false
    @Published var isPaired = false
    @Published var error: String?
    @Published var isConnected = false
    @Published var firmwareVersion: String?
    @Published var runMode: RunMode = .stop

    private let pumpManager: EquilPumpManager?
    private let nextStep: () -> Void

    init(_ pumpManager: EquilPumpManager?, nextStep: @escaping () -> Void) {
        self.pumpManager = pumpManager
        self.nextStep = nextStep
        self.firmwareVersion = pumpManager?.state.firmwareVersion
        self.runMode = pumpManager?.state.runMode ?? .stop
        self.isConnected = pumpManager?.isConnected ?? false

        pumpManager?.addStatusObserver(self, queue: processQueue)
    }

    deinit {
        pumpManager?.removeStatusObserver(self)
    }

    func pair() {
        guard let pumpManager = pumpManager else {
            nextStep()
            return
        }

        isPairing = true
        error = nil

        pumpManager.pairAndVerify { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isPairing = false

                switch result {
                case .success:
                    self.isPaired = true
                    self.firmwareVersion = pumpManager.state.firmwareVersion
                    self.runMode = pumpManager.state.runMode
                    self.nextStep()

                case let .failure(error):
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

extension EquilPairingViewModel: PumpManagerStatusObserver {
    func pumpManager(_: PumpManager, didUpdate _: PumpManagerStatus, oldStatus _: PumpManagerStatus) {
        guard let pumpManager = pumpManager else { return }
        DispatchQueue.main.async {
            self.isConnected = pumpManager.isConnected
        }
    }
}