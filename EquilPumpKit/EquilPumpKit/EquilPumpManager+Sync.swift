import Foundation
import LoopKit
import EquilKit

/// `EquilPumpManager` 的同步逻辑：`ensureCurrentPumpData`、广播遥测解码、历史游标追赶。
///
/// 对照 AAPS `EquilManager` 的 `decodeData`（被动广播）与 `loadEquilHistory`（历史追赶）。
/// AAPS v39 起停用主动轮询，电量/药量/运行模式主要来自广播；本驱动保留一条低频主动同步
/// （运行模式 + 药量 + TBR + 历史）以满足 LoopKit `ensureCurrentPumpData` 的契约。
extension EquilPumpManager {

    /// 每次同步最多回放的历史条目数（防首次对齐时回放整段历史）。
    static var maxHistoryRecordsPerSync: Int { 20 }

    // MARK: - ensureCurrentPumpData

    public func ensureCurrentPumpData(completion: ((Date?) -> Void)?) {
        guard state.isOnboarded, state.isPumpInitialized else {
            EquilLog.info("ensureCurrentPumpData: pump not ready (onboarded=\(state.isOnboarded) initialized=\(state.isPumpInitialized))")
            completion?(nil)
            return
        }

        let age = Date.now.timeIntervalSince(state.lastSync)
        guard age > Self.loopSyncFreshnessInterval else {
            EquilLog.info("ensureCurrentPumpData: data fresh (\(Int(age))s), skipping")
            completion?(nil)
            return
        }

        syncPumpData(completion: completion)
    }

    /// 主动同步：运行模式 → 药量 → 当前 TBR → 历史追赶。
    ///
    /// 全部命令走 `EquilCommandExecutor` 的单槽串行（自动绑定/解绑、节流、重试自愈）。
    public func syncPumpData(completion: ((Date?) -> Void)?) {
        EquilLog.info("syncPumpData start")
        workQueue.async { [weak self] in
            guard let self = self else { completion?(nil); return }

            let modelCmd = CmdModelGet(settings: self.state)
            self.executor.run(modelCmd) { [weak self] finished in
                guard let self = self else { return }
                if finished.cmdStatus, let model = finished as? CmdModelGet {
                    self.state.runModeRaw = model.mode
                }

                let insulinCmd = CmdInsulinGet(settings: self.state)
                self.executor.run(insulinCmd) { [weak self] finished in
                    guard let self = self else { return }
                    if finished.cmdStatus, let insulin = finished as? CmdInsulinGet {
                        self.state.reservoirUnits = Double(insulin.insulin)
                    }

                    let tbrCmd = CmdTempBasalGet(settings: self.state)
                    self.executor.run(tbrCmd) { [weak self] finished in
                        guard let self = self else { return }
                        if finished.cmdStatus, let tbr = finished as? CmdTempBasalGet {
                            self.applyTempBasalQuery(step: tbr.step, minutes: tbr.time)
                        }

                        self.syncHistory {
                            self.state.lastSync = Date.now
                            self.emitReservoirLevel(at: self.state.lastSync)
                            self.notifyStateDidChange()
                            EquilLog.info("syncPumpData done")
                            completion?(self.state.lastSync)
                        }
                    }
                }
            }
        }
    }

    /// 把 TBR 查询结果落到本地剂量状态。`step == 0 || minutes == 0` 表示当前无 TBR。
    func applyTempBasalQuery(step: Int, minutes: Int) {
        guard step > 0, minutes > 0 else {
            state.basalDose = UnfinalizedDose(basalRate: state.currentBaseBasalRate, insulinType: state.insulinType)
            return
        }
        // 反解：step = (insulin / 0.05 * 8) / 2 → insulin = step * 0.0125。
        let rate = Double(step) * 0.0125
        state.basalDose = UnfinalizedDose(
            tempRate: rate,
            duration: TimeInterval.minutes(minutes),
            insulinType: state.insulinType,
            automatic: true
        )
    }

    // MARK: - 历史追赶

    /// 从 `startHistoryIndex` 追到广播给出的 `historyIndex`（每次同步有上限）。
    func syncHistory(completion: @escaping () -> Void) {
        let target = state.historyIndex

        // 首次同步：游标为 0 且泵已有历史，直接对齐到最近一条，避免回放整段历史。
        if state.startHistoryIndex == 0, target > 0 {
            state.startHistoryIndex = max(0, target - 1)
        }

        var remaining = Self.maxHistoryRecordsPerSync

        func step() {
            guard remaining > 0, state.startHistoryIndex < state.historyIndex else {
                completion()
                return
            }
            remaining -= 1
            let nextIndex = state.startHistoryIndex + 1
            let cmd = CmdHistoryGet(currentIndex: nextIndex, settings: state)
            executor.run(cmd, maxRetries: 1) { [weak self] finished in
                guard let self = self,
                      let history = finished as? CmdHistoryGet,
                      history.cmdStatus, history.enacted
                else {
                    completion()
                    return
                }
                self.state.startHistoryIndex = nextIndex
                self.handleHistoryRecord(history)
                step()
            }
        }

        step()
    }

    /// 解码一条历史记录。已知告警码：(4,8,0) 推杆回退、(5,1,0) 异常断电重启。
    func handleHistoryRecord(_ history: CmdHistoryGet) {
        let kind: EquilAlarm.Kind
        let message: String
        switch (history.type, history.level, history.parm) {
        case (4, 8, 0):
            kind = .pushrodRewind
            message = "推杆回退"
        case (5, 1, 0):
            kind = .powerLoss
            message = "泵异常断电重启"
        default:
            return
        }

        let alarm = EquilAlarm(
            kind: kind,
            code: (history.type << 16) | (history.level << 8) | history.parm,
            occurredAt: historyDate(history),
            message: message
        )

        guard state.lastAlarm != alarm else { return }
        state.lastAlarm = alarm
        emitPumpEvents([NewPumpEvent.alarm(alarm)])
        emitAlert(EquilAlert.from(alarm))
    }

    private func historyDate(_ history: CmdHistoryGet) -> Date {
        var comps = DateComponents()
        comps.year = history.year < 100 ? history.year + 2000 : history.year
        comps.month = history.month
        comps.day = history.day
        comps.hour = history.hour
        comps.minute = history.minute
        comps.second = history.second
        return Calendar.current.date(from: comps) ?? Date()
    }

    // MARK: - 广播遥测

    /// 解码泵周期广播（28 字节）并更新遥测与告警。
    func handleAdvertisement(_ bytes: [UInt8]) {
        guard let adv = EquilAdvertisement.parse(bytes) else { return }

        state.lastCommunication = Date.now
        state.batteryPercent = adv.batteryPercent
        state.reservoirUnits = adv.reservoirUnits
        state.historyIndex = adv.historyIndex

        if let alarm = adv.alarm, state.lastAlarm != alarm {
            state.lastAlarm = alarm
            emitPumpEvents([NewPumpEvent.alarm(alarm)])
            emitAlert(EquilAlert.from(alarm))
        }

        checkThresholdAlerts()
        notifyStateDidChange()
        issueHeartbeatIfNeeded()
    }

    /// 低电量/低药量边沿告警（阈值穿越时触发一次，恢复后重置）。
    private func checkThresholdAlerts() {
        if state.batteryPercent > 0, state.batteryPercent <= Self.lowBatteryThreshold {
            if !didAlertLowBattery {
                didAlertLowBattery = true
                emitAlert(.lowBattery(percent: state.batteryPercent))
            }
        } else {
            didAlertLowBattery = false
        }

        if state.reservoirUnits <= Self.lowReservoirThreshold {
            if !didAlertLowReservoir {
                didAlertLowReservoir = true
                emitAlert(.lowReservoir(level: state.reservoirUnits))
            }
        } else {
            didAlertLowReservoir = false
        }
    }
}