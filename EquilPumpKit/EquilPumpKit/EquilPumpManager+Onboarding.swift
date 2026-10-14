import Foundation
import LoopKit
import EquilKit

/// `EquilPumpManager` 的向导与维护命令：显式配对、设备校验、更换储药器。
///
/// 这些流程需要用户在场（输入泵号/密码、插管换药），因此由向导显式触发，
/// 并在执行期间抑制 auto-unpair（`executor.setWizardActive(true)`），
/// 结束后由 `endWizard()` 恢复"用完即走"的空闲解绑调度。
///
/// 对照 AAPS `EquilManager` 的 `pairEquil` / `setInsulinChange` / 定位循环逻辑。
extension EquilPumpManager {

    // MARK: - 配对

    /// 显式配对并校验（向导用）。成功写入固件版本、设备标识与会话密码。
    ///
    /// 与业务命令的隐式配对不同：这里强制一次全新 `CmdPair`，再读回设备信息确认连通。
    public func pairAndVerify(completion: @escaping (Result<Void, Error>) -> Void) {
        guard !state.serialNumber.isEmpty, !state.password.isEmpty else {
            completion(.failure(EquilPumpError.missingPairingInfo))
            return
        }

        executor.setWizardActive(true)
        EquilLog.info("pairAndVerify sn=\(state.serialNumber)")

        executor.pairNow { [weak self] paired in
            guard let self = self else {
                completion(.success(()))
                return
            }
            guard paired else {
                completion(.failure(EquilPumpError.connectionFailed))
                return
            }
            self.verifyPump(completion: completion)
        }
    }

    /// 结束向导：恢复 auto-unpair 调度（若仍绑定）。
    public func endWizard() {
        executor.setWizardActive(false)
    }

    // MARK: - 设备校验

    /// 读取设备信息与关键状态（不要求 `isPumpInitialized`）。向导校验与设置页刷新用。
    ///
    /// 顺序：`CmdDevicesGet`（固件）→ `CmdModelGet`（运行模式）→ `CmdInsulinGet`（药量）。
    /// 任一步成功即更新对应字段；设备信息读取失败视为配对未生效。
    public func verifyPump(completion: @escaping (Result<Void, Error>) -> Void) {
        let devices = CmdDevicesGet(settings: state)
        executor.run(devices, needsBinding: false, maxRetries: 2) { [weak self] finished in
            guard let self = self else {
                completion(.success(()))
                return
            }
            guard let devices = finished as? CmdDevicesGet, devices.cmdStatus else {
                EquilLog.warn("verifyPump: devices read failed")
                completion(.failure(EquilPumpError.connectionFailed))
                return
            }
            if !devices.firmwareVersion.isEmpty {
                self.state.firmwareVersion = devices.firmwareVersion
            }

            let model = CmdModelGet(settings: self.state)
            self.executor.run(model, needsBinding: false, maxRetries: 2) { [weak self] finished in
                guard let self = self else {
                    completion(.success(()))
                    return
                }
                if let model = finished as? CmdModelGet, model.cmdStatus {
                    self.state.runModeRaw = model.mode
                    self.state.isPumpInitialized = true
                }

                let insulin = CmdInsulinGet(settings: self.state)
                self.executor.run(insulin, needsBinding: false, maxRetries: 2) { [weak self] finished in
                    guard let self = self else {
                        completion(.success(()))
                        return
                    }
                    if let insulin = finished as? CmdInsulinGet, insulin.cmdStatus {
                        self.state.reservoirUnits = Double(insulin.insulin)
                    }
                    let now = Date.now
                    self.state.lastSync = now
                    self.state.lastCommunication = now
                    self.notifyStateDidChange()
                    self.emitReservoirLevel(at: now)
                    EquilLog.info("verifyPump ok fw=\(self.state.firmwareVersion ?? "nil") mode=\(self.state.runModeRaw)")
                    completion(.success(()))
                }
            }
        }
    }

    // MARK: - 更换储药器

    /// 定位循环的迭代上限（每步 `stepFill` 步，约 160 步/次）。
    /// 满行程 32000 步约需 200 次；上限设 400 防泵异常时无限循环。
    static var maxPositioningSteps: Int { 400 }

    /// 更换储药器：推杆回退到底（`CmdInsulinChange`）→ 步进填充至顶到活塞（定位循环）。
    ///
    /// 对照 AAPS `setInsulinChange`：换管后推杆回退 `stepMax`，再循环"步进 + 读接触阻力"
    /// 直到阻力越过阈值（顶到活塞）。阈值世代由固件版本决定（见 `CmdResistanceGet`）。
    public func changeReservoir(completion: @escaping (Result<Void, Error>) -> Void) {
        executor.setWizardActive(true)
        EquilLog.info("changeReservoir start")

        let change = CmdInsulinChange(settings: state)
        runEquilCommand(change, maxRetries: 2) { [weak self] result in
            guard let self = self else {
                completion(.success(()))
                return
            }
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case .success:
                self.runPositioningLoop(remaining: Self.maxPositioningSteps, completion: completion)
            }
        }
    }

    /// 推杆定位循环：反复"步进 + 读接触阻力"，顶到活塞（阻力过阈值）即停。
    ///
    /// 递归经命令队列异步续跑，不增长调用栈；`CmdResistanceGet.enacted` 即"已顶到活塞"。
    private func runPositioningLoop(remaining: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        guard remaining > 0 else {
            EquilLog.warn("positioning loop hit iteration cap, treating as done")
            finishReservoirChange(completion: completion)
            return
        }

        let step = CmdStepSet(sendConfig: false, step: EquilConst.stepFill, settings: state)
        executor.run(step, maxRetries: 2) { [weak self] _ in
            guard let self = self else {
                completion(.success(()))
                return
            }

            let resistance = CmdResistanceGet(firmwareVersion: self.state.firmwareVersion, settings: self.state)
            self.executor.run(resistance, maxRetries: 2) { [weak self] finished in
                guard let self = self else {
                    completion(.success(()))
                    return
                }
                if let resistance = finished as? CmdResistanceGet, resistance.cmdStatus, resistance.enacted {
                    EquilLog.info("positioning reached piston value=\(resistance.value) threshold=\(resistance.threshold)")
                    self.finishReservoirChange(completion: completion)
                } else {
                    self.runPositioningLoop(remaining: remaining - 1, completion: completion)
                }
            }
        }
    }

    private func finishReservoirChange(completion: @escaping (Result<Void, Error>) -> Void) {
        let now = Date.now
        state.isPumpInitialized = true
        state.lastSync = now
        state.lastCommunication = now
        notifyStateDidChange()
        emitReservoirLevel(at: now)
        EquilLog.info("changeReservoir done")
        completion(.success(()))
    }
}