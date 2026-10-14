import EquilPumpKit
import LoopKit
import LoopKitUI

/// 更换储药器页的视图模型。
///
/// 调用驱动层的 `changeReservoir`：推杆回退到底 → 步进填充至顶到活塞（定位循环）。
/// 定位循环由固件交互驱动，无进度回报，界面以不确定进度指示 + 状态文案呈现。
class EquilReservoirChangeViewModel: ObservableObject {
    private let processQueue = DispatchQueue(label: "com.equilpumpkit.reservoirChangeViewModel")

    @Published var isChanging = false
    @Published var error: String?
    @Published var isPumpInitialized = false

    private let pumpManager: EquilPumpManager?
    private let onDone: () -> Void

    init(_ pumpManager: EquilPumpManager?, onDone: @escaping () -> Void) {
        self.pumpManager = pumpManager
        self.onDone = onDone
        self.isPumpInitialized = pumpManager?.state.isPumpInitialized ?? false
    }

    func start() {
        guard let pumpManager = pumpManager else {
            onDone()
            return
        }

        isChanging = true
        error = nil

        pumpManager.changeReservoir { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isChanging = false

                switch result {
                case .success:
                    self.isPumpInitialized = true
                    self.onDone()

                case let .failure(error):
                    self.error = error.localizedDescription
                }
            }
        }
    }
}