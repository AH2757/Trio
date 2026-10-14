import EquilPumpKit
import LoopKit
import LoopKitUI

/// 手动临时基础率页的视图模型，对照 MedtrumKit `ManualTempBasalViewModel`。
///
/// 与 Medtrum 的差异：Equil 基础率步进 0.01 U/h、上限 3.0 U/h，速率网格直接取驱动的
/// `onboardingSupportedBasalRates`（过滤出 >0 且 <10 的部分）。
class EquilManualTempBasalViewModel: ObservableObject {
    @Published var selectedRate: Double = 0.05
    @Published var selectedDuration: TimeInterval = .minutes(30)
    @Published var enacting = false
    @Published var enactingBolus = false
    @Published var error: String?

    let allowedRates: [Double] = EquilPumpManager.onboardingSupportedBasalRates.filter { $0 > 0 && $0 < 10 }
    let allowedDurations: [Double] = (1 ... 24).map { Double($0) * TimeInterval.minutes(30) }

    private let pumpManager: EquilPumpManager?
    private let goBack: () -> Void

    init(pumpManager: EquilPumpManager?, goBack: @escaping () -> Void) {
        self.pumpManager = pumpManager
        self.goBack = goBack

        if let pumpManager = pumpManager {
            selectedRate = pumpManager.state.currentBaseBasalRate
            enactingBolus = pumpManager.state.bolusDose != nil
            pumpManager.addStatusObserver(self, queue: DispatchQueue.main)
        }
    }

    deinit {
        pumpManager?.removeStatusObserver(self)
    }

    func rateFormatter(for rate: Double) -> String {
        String(format: "%.2f", rate) + " " + String(localized: "U/hr", comment: "Units for showing temp basal rate")
    }

    func durationFormatter(for duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            return String(
                format: String(localized: "%lld hr %lld min", comment: "temp basal duration hours+minutes"),
                hours, minutes
            )
        }
        return String(
            format: String(localized: "%lld min", comment: "temp basal duration minutes"),
            minutes
        )
    }

    func enact() {
        guard let pumpManager = pumpManager else { return }

        enacting = true
        error = nil

        pumpManager.syncPumpData { _ in
            pumpManager.enactTempBasal(
                unitsPerHour: self.selectedRate,
                duration: self.selectedDuration,
                automatic: false
            ) { error in
                DispatchQueue.main.async {
                    self.enacting = false
                    if let error = error {
                        self.error = error.localizedDescription
                    } else {
                        self.goBack()
                    }
                }
            }
        }
    }
}

extension EquilManualTempBasalViewModel: PumpManagerStatusObserver {
    func pumpManager(_: PumpManager, didUpdate _: PumpManagerStatus, oldStatus _: PumpManagerStatus) {
        DispatchQueue.main.async {
            self.enactingBolus = self.pumpManager?.state.bolusDose != nil
        }
    }
}