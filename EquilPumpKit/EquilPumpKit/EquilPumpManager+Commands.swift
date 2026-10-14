import Foundation
import HealthKit
import LoopKit
import EquilKit

/// `EquilPumpManager` 的剂量命令实现：大剂量、TBR、暂停/恢复、基础率表与限值。
///
/// 对照 AAPS `EquilPump` 的命令下发路径，并参照 MedtrumKit `MedtrumPumpManager` 的
/// LoopKit 对接方式。所有命令都走 `EquilCommandExecutor` 的"用完即走 + 单槽串行 + 重试自愈"。
///
/// 硬约束（`docs/08-AAPS可借鉴逻辑清单.md`）：
/// - 剂量下发前泵必须处于 `RunMode.run`（暂停/停止态一律拒绝，与 AAPS 一致）；
/// - 大剂量与 TBR 互斥（泵不支持同时输注）；
/// - Equil 不回传逐滴进度，大剂量按设定速率线性估算、到时收尾。
extension EquilPumpManager {

    // MARK: - 速率换算

    /// 泵端大剂量输注速率（U/min）。`state.bolusRate` 为枚举 ×10（15 → 1.5 U/min）。
    var bolusRateUnitsPerMinute: Double {
        let rate = Double(state.bolusRate) / 10.0
        return rate > 0 ? rate : Double(EquilConst.bolusRateDefault) / 10.0
    }

    // MARK: - 进度与时长

    public func createBolusProgressReporter(reportingOn dispatchQueue: DispatchQueue) -> DoseProgressReporter? {
        guard let dose = state.bolusDose else { return nil }
        return EquilBolusProgressReporter(pumpManager: self, dose: dose, reportingQueue: dispatchQueue)
    }

    public func estimatedDuration(toBolus units: Double) -> TimeInterval {
        TimeInterval.minutes(units / bolusRateUnitsPerMinute)
    }

    // MARK: - 前置检查

    /// 剂量下发前的通用前置检查（已配置、已初始化、已配对、运行态）。
    func dosingPrecondition() -> EquilPumpError? {
        guard state.isOnboarded else { return .notOnboarded }
        guard state.isPumpInitialized else { return .pumpNotInitialized }
        guard !state.serialNumber.isEmpty, !state.password.isEmpty else { return .missingPairingInfo }
        guard state.isRunning else { return .notRunning }
        return nil
    }

    /// 在命令执行器上串行跑一条命令，把链路结果归一成 `Result`。
    func runEquilCommand<T: BaseCmd>(
        _ cmd: T,
        maxRetries: Int = 2,
        completion: @escaping (Result<T, EquilPumpError>) -> Void
    ) {
        executor.run(cmd, maxRetries: maxRetries) { finished in
            guard let typed = finished as? T else {
                completion(.failure(.commandTimeout))
                return
            }
            if typed.cmdStatus && typed.enacted {
                completion(.success(typed))
            } else if typed.resolvedResult == .connectError {
                completion(.failure(.connectionFailed))
            } else {
                completion(.failure(.commandFailed(typed.resolvedResult)))
            }
        }
    }

    // MARK: - 大剂量

    public func enactBolus(
        units: Double,
        activationType: BolusActivationType,
        completion: @escaping (PumpManagerError?) -> Void
    ) {
        if let error = dosingPrecondition() {
            completion(error.asPumpManagerError)
            return
        }
        guard units > 0 else {
            completion(EquilPumpError.unsupported("大剂量必须大于 0").asPumpManagerError)
            return
        }
        guard state.bolusDose == nil else {
            completion(EquilPumpError.isBolussing.asPumpManagerError)
            return
        }

        let duration = estimatedDuration(toBolus: units)
        EquilLog.info("enactBolus \(units)U duration=\(Int(duration))s")

        let cmd = CmdLargeBasalSet(insulin: units, settings: state)
        runEquilCommand(cmd) { [weak self] result in
            guard let self = self else {
                completion(nil)
                return
            }
            switch result {
            case let .failure(error):
                completion(error.asPumpManagerError)

            case .success:
                let dose = UnfinalizedDose(
                    units: units,
                    duration: duration,
                    activationType: activationType,
                    insulinType: self.state.insulinType
                )
                self.state.bolusDose = dose
                self.state.lastSync = Date.now
                self.emitPumpEvents([NewPumpEvent.bolus(unfinalizedDose: dose)], replacePendingEvents: false)
                self.notifyStateDidChange()
                self.scheduleBolusFinalize(for: dose)
                completion(nil)
            }
        }
    }

    public func cancelBolus(completion: @escaping (PumpManagerResult<DoseEntry?>) -> Void) {
        guard let dose = state.bolusDose else {
            completion(.success(nil))
            return
        }

        state.cancelingBolusSince = Date.now
        notifyStateDidChange()

        // 取消时按已输注时间估算实际输注量（泵不回传进度）。
        let delivered = estimatedDelivered(for: dose)
        let cmd = CmdLargeBasalSet(insulin: 0, settings: state)
        runEquilCommand(cmd) { [weak self] result in
            guard let self = self else {
                completion(.success(nil))
                return
            }
            self.state.cancelingBolusSince = nil

            switch result {
            case let .failure(error):
                self.notifyStateDidChange()
                completion(.failure(error.asPumpManagerError))

            case .success:
                self.bolusFinalizeWork?.cancel()
                self.bolusFinalizeWork = nil
                dose.deliveredUnits = delivered
                let entry = dose.toDoseEntry(isMutable: false, endDate: Date.now)
                self.state.bolusDose = nil
                self.state.lastSync = Date.now

                var events = self.runningTempBasal()
                events.append(NewPumpEvent.bolus(dose: entry))
                self.notifyStateDidChange()
                self.emitPumpEvents(events)
                completion(.success(entry))
            }
        }
    }

    /// 大剂量到时收尾：Equil 不回报完成事件，按估算时长线性推进后定稿。
    func scheduleBolusFinalize(for dose: UnfinalizedDose) {
        bolusFinalizeWork?.cancel()
        let delay = max(dose.estimatedEndDate.timeIntervalSinceNow, 0) + 1.0
        let work = DispatchWorkItem { [weak self] in self?.finalizeBolus() }
        bolusFinalizeWork = work
        workQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func finalizeBolus(deliveredUnits: Double? = nil) {
        guard let dose = state.bolusDose else { return }
        bolusFinalizeWork?.cancel()
        bolusFinalizeWork = nil

        dose.deliveredUnits = deliveredUnits ?? dose.value
        let entry = dose.toDoseEntry(isMutable: false, useEstimatedEndDate: true)
        state.bolusDose = nil
        state.lastSync = Date.now

        var events = runningTempBasal()
        events.append(NewPumpEvent.bolus(dose: entry))
        notifyStateDidChange()
        emitPumpEvents(events)
        emitReservoirLevel()
    }

    // MARK: - 临时基础率

    public func enactTempBasal(
        unitsPerHour: Double,
        for duration: TimeInterval,
        completion: @escaping (PumpManagerError?) -> Void
    ) {
        enactTempBasal(unitsPerHour: unitsPerHour, duration: duration, automatic: true, completion: completion)
    }

    /// 手动临时基础率（`automatic: false`）供 UI 使用；算法路径走无参重载（`automatic: true`）。
    public func enactTempBasal(
        unitsPerHour: Double,
        duration: TimeInterval,
        automatic: Bool,
        completion: @escaping (PumpManagerError?) -> Void
    ) {
        if let error = dosingPrecondition() {
            completion(error.asPumpManagerError)
            return
        }
        guard state.bolusDose == nil else {
            completion(EquilPumpError.isBolussing.asPumpManagerError)
            return
        }

        // duration 为 0 表示取消当前 TBR（对照 LoopKit 契约）；泵端以 step=0 表示取消。
        let canceling = duration <= 0
        let minutes = canceling ? 0 : max(1, Int((duration / 60).rounded()))
        let rate = canceling ? 0 : roundToSupportedBasalRate(unitsPerHour: unitsPerHour)
        EquilLog.info("enactTempBasal rate=\(rate) min=\(minutes) cancel=\(canceling)")

        let cmd = CmdTempBasalSet(insulin: rate, duration: minutes, cancel: canceling, settings: state)
        runEquilCommand(cmd) { [weak self] result in
            guard let self = self else {
                completion(nil)
                return
            }
            switch result {
            case let .failure(error):
                completion(error.asPumpManagerError)

            case .success:
                let now = Date.now
                var events = self.finalizedTempBasal(endedAt: now)

                if canceling {
                    let basalDose = UnfinalizedDose(
                        basalRate: self.state.currentBaseBasalRate,
                        insulinType: self.state.insulinType,
                        startDate: now
                    )
                    events.append(NewPumpEvent.basal(dose: basalDose.toDoseEntry()))
                    self.state.basalDose = basalDose
                } else {
                    let tempDose = UnfinalizedDose(
                        tempRate: rate,
                        duration: TimeInterval.minutes(minutes),
                        insulinType: self.state.insulinType,
                        automatic: automatic
                    )
                    events.append(NewPumpEvent.tempBasal(dose: tempDose.toDoseEntry(isMutable: true)))
                    self.state.basalDose = tempDose
                }

                self.state.lastSync = now
                self.notifyStateDidChange()
                self.emitPumpEvents(events)
                completion(nil)
            }
        }
    }

    // MARK: - 暂停 / 恢复

    public func suspendDelivery(completion: @escaping (Error?) -> Void) {
        let cmd = CmdModelSet(mode: RunMode.suspend.rawValue, settings: state)
        runEquilCommand(cmd) { [weak self] result in
            guard let self = self else {
                completion(nil)
                return
            }
            switch result {
            case let .failure(error):
                completion(error)

            case .success:
                let now = Date.now
                let dose = UnfinalizedDose(suspendStartTime: now)

                var events = self.finalizedTempBasal(endedAt: now)
                events.append(NewPumpEvent.suspend(dose: dose.toDoseEntry()))

                self.state.basalDose = dose
                self.state.runModeRaw = RunMode.suspend.rawValue
                self.state.lastSync = now
                self.notifyStateDidChange()
                self.emitPumpEvents(events)
                completion(nil)
            }
        }
    }

    public func resumeDelivery(completion: @escaping (Error?) -> Void) {
        let cmd = CmdModelSet(mode: RunMode.run.rawValue, settings: state)
        runEquilCommand(cmd) { [weak self] result in
            guard let self = self else {
                completion(nil)
                return
            }
            switch result {
            case let .failure(error):
                completion(error)

            case .success:
                let now = Date.now
                let dose = UnfinalizedDose(resumeStartTime: now, insulinType: self.state.insulinType)

                var events = self.runningTempBasal()
                events.append(NewPumpEvent.resume(dose: dose.toDoseEntry()))

                self.state.basalDose = dose
                self.state.runModeRaw = RunMode.run.rawValue
                self.state.lastSync = now
                self.notifyStateDidChange()
                self.emitPumpEvents(events)
                completion(nil)
            }
        }
    }

    // MARK: - 基础率表

    public func syncBasalRateSchedule(
        items scheduleItems: [RepeatingScheduleValue<Double>],
        completion: @escaping (Result<BasalRateSchedule, Error>) -> Void
    ) {
        guard let dailySchedule = DailyValueSchedule<Double>(dailyItems: scheduleItems) else {
            completion(.failure(EquilPumpError.unsupported("基础率表为空")))
            return
        }

        let entries = EquilPumpManager.hourlyBasalEntries(from: scheduleItems)
        let schedule = BasalSchedule(entries: entries.map {
            BasalScheduleEntry(rate: $0.rate, startTimeSeconds: $0.startTimeSeconds)
        })
        EquilLog.info("syncBasalRateSchedule entries=\(entries.count)")

        let cmd = CmdBasalSet(basalSchedule: schedule, settings: state)
        runEquilCommand(cmd) { [weak self] result in
            guard let self = self else {
                completion(.success(dailySchedule))
                return
            }
            switch result {
            case let .failure(error):
                completion(.failure(error))

            case .success:
                self.state.basalSchedule = entries
                self.state.lastSync = Date.now
                self.notifyStateDidChange()
                completion(.success(dailySchedule))
            }
        }
    }

    /// 把 LoopKit 的任意时段基础率表展开成泵要求的 24 段整点表。
    public static func hourlyBasalEntries(from items: [RepeatingScheduleValue<Double>]) -> [EquilBasalEntry] {
        let sorted = items.sorted { $0.startTime < $1.startTime }
        return (0..<24).map { hour in
            let offset = Double(hour * 3600)
            let rate = sorted.last(where: { $0.startTime <= offset })?.value ?? sorted.first?.value ?? 0
            return EquilBasalEntry(startTimeSeconds: hour * 3600, rate: EquilPumpManager.roundBasalRate(rate))
        }
    }

    // MARK: - 限值

    public func syncDeliveryLimits(
        limits deliveryLimits: DeliveryLimits,
        completion: @escaping (Result<DeliveryLimits, Error>) -> Void
    ) {
        let maxBolus = deliveryLimits.maximumBolus?.doubleValue(for: .internationalUnit())
        // LoopKit's HKUnit.internationalUnitsPerHour is internal to that module, so build the
        // equivalent unit from public HealthKit APIs instead.
        let maxBasalUnit = HKUnit.internationalUnit().unitDivided(by: .hour())
        let maxBasalRate = deliveryLimits.maximumBasalRate?.doubleValue(for: maxBasalUnit)
        EquilLog.info("syncDeliveryLimits maxBolus=\(String(describing: maxBolus)) maxBasal=\(String(describing: maxBasalRate))")

        let cmd = CmdSettingSet(maxBolus: maxBolus, maxBasalRate: maxBasalRate, settings: state)
        runEquilCommand(cmd) { [weak self] result in
            guard let self = self else {
                completion(.success(deliveryLimits))
                return
            }
            switch result {
            case let .failure(error):
                completion(.failure(error))

            case .success:
                if let maxBolus = maxBolus {
                    self.state.maxBolusUnits = maxBolus
                }
                if let maxBasalRate = maxBasalRate {
                    self.state.maxBasalRateUnitsPerHour = maxBasalRate
                }
                self.state.lastSync = Date.now
                self.notifyStateDidChange()
                completion(.success(deliveryLimits))
            }
        }
    }
}