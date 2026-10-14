import Foundation
import LoopKit

/// 大剂量进度估算（按时间线性推进），对照 MedtrumKit `MedtrumDoseProgressReporter`。
///
/// Equil 泵不回传逐滴进度，只按设定速率匀速输注；因此进度由
/// `(now - startDate) / (estimatedEndDate - startDate)` 估算。
final class EquilBolusProgressReporter: DoseProgressTimerEstimator {

    private let dose: UnfinalizedDose
    private weak var pumpManager: EquilPumpManager?

    init(pumpManager: EquilPumpManager, dose: UnfinalizedDose, reportingQueue: DispatchQueue) {
        self.pumpManager = pumpManager
        self.dose = dose
        super.init(reportingQueue: reportingQueue)
    }

    override var progress: DoseProgress {
        let elapsed = -dose.startDate.timeIntervalSinceNow
        let duration = max(dose.estimatedEndDate.timeIntervalSince(dose.startDate), .ulpOfOne)
        let percentComplete = min(elapsed / duration, 1)
        let delivered = pumpManager?.roundToSupportedBolusVolume(units: percentComplete * dose.value)
            ?? percentComplete * dose.value
        return DoseProgress(deliveredUnits: delivered, percentComplete: percentComplete)
    }

    override func timerParameters() -> (delay: TimeInterval, repeating: TimeInterval) {
        let timeSinceStart = dose.startDate.timeIntervalSinceNow
        let timeBetweenPulses = TimeInterval.seconds(2)
        let delayUntilNextPulse = timeBetweenPulses - timeSinceStart.remainder(dividingBy: timeBetweenPulses)
        return (delay: delayUntilNextPulse, repeating: timeBetweenPulses)
    }
}