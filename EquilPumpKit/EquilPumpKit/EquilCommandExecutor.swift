import Foundation
import EquilKit

/// 驱动层需要的额外设置（在 `EquilSettingsStore` 之上补配对所需字段）。
///
/// `EquilKit` 的命令只依赖 `equilDevices` / `equilPassword` / `bolusRate`；
/// 驱动层额外需要广播名、用户配对密码与外设标识来构造 `CmdPair` / `CmdUnPair`。
public protocol EquilPumpSettingsStore: EquilSettingsStore {
    /// 广播名（如 "Equil - D02563"）。
    var equilDeviceName: String { get }
    /// 用户输入的 6 位数字配对密码。
    var equilPairingPassword: String { get }
    /// Core Bluetooth 外设标识（iOS 无 MAC，仅作连接目标与日志）。
    var equilPeripheralIdentifier: String? { get }
}

/// 命令执行器：把 AAPS `EquilManager` 的"用完即走 + 单槽串行 + 重试"逻辑搬到 Swift。
///
/// 关键约束（来自 `Equil驱动改造完整任务书` 任务 C/D）：
/// - **单槽串行**：一次只执行一条命令，对照 AAPS 的 `cmdLock`；
/// - **用完即走**：业务命令前自动 `CmdPair` 绑定，空闲 5 秒后自动 `CmdUnPair` 并主动断连；
/// - **绑定分叉自愈**：AES 命令 `connectError`（BLE 能连但会话静默）→ 下轮强制重新绑定；
/// - **背靠背节流**：命令间最小间隔 500ms（定位/TBR/状态类 200ms）。
///
/// 线程模型：所有命令在专用串行队列上执行。`BaseCmd.waitForCompletion` 会**阻塞线程**，
/// 而 Core Bluetooth 回调默认在 `.main`，因此绝不能在主线程上等待命令完成。
public final class EquilCommandExecutor {

    /// 命令专用串行队列。
    private let queue = DispatchQueue(label: "com.equilpumpkit.command", qos: .userInitiated)

    public let link: EquilLinkController
    public let settings: EquilPumpSettingsStore

    /// 本机是否已 `CmdPair` 绑定（App 重启视为未绑定——用完即走架构的前提）。
    /// 注意：**不随链路断连重置**（对照 AAPS），仅在自动/手动解绑或自愈时清零。
    public private(set) var boundToPump = false

    /// 向导进行中：完全抑制 auto-unpair（页间阅读间隙会误触发）。
    public private(set) var wizardActive = false

    /// 闭环是否活跃（活跃期延长空闲解绑延迟，复用绑定）。
    public var closedLoopActive: (() -> Bool)?

    /// 命令结束回调（更新 `lastSync`、解码结果、触发状态刷新等）。
    public var onCommandFinished: ((BaseCmd) -> Void)?

    private var lastCmdFinishTime: Date = .distantPast
    private var autoUnpairWork: DispatchWorkItem?
    private var isExecutingCommand = false

    /// 已提交但尚未结束的命令计数。供链路层在 auto-unpair 让位判定时查询
    /// （`EquilLinkController.pumpQueuePending`）——不能用 `queue.sync` 读取，
    /// 因为链路层的 `ready()` 可能同步运行在命令队列上，会造成自死锁。
    private let pendingLock = NSLock()
    private var pendingCommandCount = 0

    public var hasPendingCommand: Bool {
        pendingLock.lock(); defer { pendingLock.unlock() }
        return pendingCommandCount > 0
    }

    public init(link: EquilLinkController, settings: EquilPumpSettingsStore) {
        self.link = link
        self.settings = settings
    }

    // MARK: - 对外入口

    /// 在命令队列上串行执行一段逻辑（不涉及命令等待时使用，如扫描/解绑）。
    public func async(_ block: @escaping () -> Void) {
        queue.async(execute: block)
    }

    /// 提交一条命令：确保绑定 → 执行 → 重试 → 完成后调度 auto-unpair。
    ///
    /// - Parameters:
    ///   - cmd: 待执行命令（调用方可保留引用以读取解析结果）。
    ///   - needsBinding: 是否属于需要绑定的 AES 业务命令（官方域/配对/解绑为 false）。
    ///   - maxRetries: 失败重试次数（总尝试 = maxRetries + 1）。
    ///   - completion: 命令队列上回调，参数即 `cmd`。
    public func run(
        _ cmd: BaseCmd,
        needsBinding: Bool = true,
        maxRetries: Int = 2,
        completion: @escaping (BaseCmd) -> Void
    ) {
        pendingLock.lock()
        pendingCommandCount += 1
        pendingLock.unlock()
        queue.async { [weak self] in
            guard let self = self else { return }
            self.cancelAutoUnpairLocked()
            self.isExecutingCommand = true

            let requiresBinding = needsBinding && self.needsPairBinding(cmd)

            if requiresBinding && !self.boundToPump {
                guard self.ensurePumpBoundLocked() else {
                    cmd.resolvedResult = .connectError
                    self.finish(cmd, scheduleUnpair: false, completion: completion)
                    return
                }
            }

            self.executeWithRetryLocked(
                cmd,
                maxRetries: maxRetries,
                requiresBinding: requiresBinding,
                completion: completion
            )
        }
    }

    /// 显式配对（向导/设置页用）：强制一次全新 `CmdPair` 并置为已绑定。
    ///
    /// 与业务命令的隐式配对（`ensurePumpBoundLocked`）不同：这里即使本机认为已绑定
    /// 也会重发一次 `CmdPair`，用于向导校验与"重新绑定"。成功后按需安排 auto-unpair
    /// （向导期间由 `wizardActive` 抑制）。
    public func pairNow(completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { completion(false); return }
            self.cancelAutoUnpairLocked()
            self.boundToPump = false
            let ok = self.ensurePumpBoundLocked()
            self.lastCmdFinishTime = Date.now
            if ok {
                self.scheduleAutoUnpairLocked()
            }
            completion(ok)
        }
    }

    /// 设置向导状态。向导期间抑制 auto-unpair；结束时若仍绑定则恢复调度。
    public func setWizardActive(_ active: Bool) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.wizardActive = active
            if active {
                self.cancelAutoUnpairLocked()
            } else if self.boundToPump {
                self.scheduleAutoUnpairLocked()
            }
        }
    }

    /// 立即解绑并断连（手动解绑/换药收尾/停用驱动）。
    public func unpairNow(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.cancelAutoUnpairLocked()
            if self.boundToPump {
                let unpair = self.makeUnPair(auto: false)
                self.link.writeCmd(unpair)
                _ = unpair.waitForCompletion(budgetMs: self.waitBudget(for: unpair))
                self.boundToPump = false
            }
            self.link.disconnect()
            completion?()
        }
    }

    /// 直接断连（不解绑），用于释放链路。
    public func disconnectNow() {
        queue.async { [weak self] in
            self?.cancelAutoUnpairLocked()
            self?.link.disconnect()
        }
    }

    /// 新命令入口取消挂起的自动解绑（由驱动层在队列外调用时使用）。
    public func cancelAutoUnpair() {
        queue.async { [weak self] in self?.cancelAutoUnpairLocked() }
    }

    // MARK: - 绑定

    private func needsPairBinding(_ cmd: BaseCmd) -> Bool {
        !(cmd is CmdPair) && !(cmd is CmdUnPair) && !(cmd is EquilOfficialCommand)
    }

    /// 确保泵已绑定：未绑定时执行一次 `CmdPair`。
    private func ensurePumpBoundLocked() -> Bool {
        guard !boundToPump else { return true }

        let pair = CmdPair(
            name: settings.equilDeviceName,
            address: settings.equilPeripheralIdentifier ?? settings.equilDeviceName,
            password: settings.equilPairingPassword,
            settings: settings
        )
        pair.resolvedResult = .none
        pair.cmdStatus = false

        link.writeCmd(pair)
        _ = pair.waitForCompletion(budgetMs: waitBudget(for: pair))
        lastCmdFinishTime = Date.now

        let ok = pair.cmdStatus && pair.enacted
        if ok {
            boundToPump = true
            link.markSessionValid()
            EquilLog.info("ensurePumpBound: paired")
        } else {
            boundToPump = false
            EquilLog.warn("ensurePumpBound: pair failed result=\(pair.resolvedResult)")
        }
        return ok
    }

    private func makeUnPair(auto: Bool) -> CmdUnPair {
        let unpair = CmdUnPair(
            name: settings.equilDeviceName,
            password: settings.equilPairingPassword,
            settings: settings
        )
        unpair.fromAutoUnpair = auto
        return unpair
    }

    // MARK: - 重试执行

    private func executeWithRetryLocked(
        _ cmd: BaseCmd,
        maxRetries: Int,
        requiresBinding: Bool,
        completion: @escaping (BaseCmd) -> Void
    ) {
        let attempts = max(1, maxRetries + 1)
        var attempt = 0

        while attempt < attempts {
            attempt += 1

            // 每轮重置命令状态，防重试空转（对照 AAPS）。
            cmd.resolvedResult = .none
            cmd.cmdStatus = false
            cmd.enacted = true

            enforceMinIntervalLocked(for: cmd)

            link.writeCmd(cmd)
            _ = cmd.waitForCompletion(budgetMs: waitBudget(for: cmd))

            if cmd.cmdStatus && cmd.enacted {
                finish(cmd, scheduleUnpair: requiresBinding, completion: completion)
                return
            }

            switch cmd.resolvedResult {
            case .connectError where requiresBinding:
                // 绑定分叉自愈：App 以为绑定、泵已解绑 → 下轮强制重新 CmdPair。
                boundToPump = false
            case .notFound:
                // auto-unpair 让位：命令未执行，交给队列复用连接。
                finish(cmd, scheduleUnpair: requiresBinding, completion: completion)
                return
            default:
                break
            }

            if attempt < attempts {
                Thread.sleep(forTimeInterval: retryDelayLocked(for: cmd, result: cmd.resolvedResult))
            }
        }

        // 全部失败：清挂起命令，防延迟投递造成泵/App 状态分叉。
        link.cancelPendingCommand()
        finish(cmd, scheduleUnpair: requiresBinding, completion: completion)
    }

    private func finish(_ cmd: BaseCmd, scheduleUnpair: Bool, completion: @escaping (BaseCmd) -> Void) {
        isExecutingCommand = false
        lastCmdFinishTime = Date.now
        pendingLock.lock()
        if pendingCommandCount > 0 { pendingCommandCount -= 1 }
        pendingLock.unlock()
        onCommandFinished?(cmd)
        if scheduleUnpair {
            scheduleAutoUnpairLocked()
        }
        completion(cmd)
    }

    // MARK: - 节流

    private func enforceMinIntervalLocked(for cmd: BaseCmd) {
        let interval = minInterval(for: cmd)
        let elapsed = Date.now.timeIntervalSince(lastCmdFinishTime)
        if elapsed < interval {
            Thread.sleep(forTimeInterval: interval - elapsed)
        }
    }

    /// 背靠背最小间隔：定位循环/TBR/状态查询走快速白名单，其余 500ms。
    private func minInterval(for cmd: BaseCmd) -> TimeInterval {
        if cmd is CmdStepSet || cmd is CmdResistanceGet || cmd is CmdTempBasalSet
            || cmd is CmdTempBasalGet || cmd is CmdModelGet {
            return Double(EquilConst.bleCmdFastInterval) / 1000
        }
        return Double(EquilConst.bleCmdMinInterval) / 1000
    }

    /// 等待预算：命令超时 + （链路未就绪时）连接超时 + 2s 余量。
    private func waitBudget(for cmd: BaseCmd) -> Int64 {
        let connect = link.isGattReady ? 0 : Int64(cmd.connectTimeOut)
        return Int64(cmd.timeOut) + connect + 2000
    }

    private func retryDelayLocked(for cmd: BaseCmd, result: ResolvedResult) -> TimeInterval {
        if result == .connectError || result == .notFound { return 0.5 }
        // 定位循环丢帧后同连接直接重发即成功，用更短延迟。
        if cmd is CmdStepSet || cmd is CmdResistanceGet { return 0.3 }
        return 0.8
    }

    // MARK: - 自动解绑（用完即走）

    private func scheduleAutoUnpairLocked() {
        guard boundToPump, !wizardActive else { return }
        autoUnpairWork?.cancel()
        let delayMs = (closedLoopActive?() == true)
            ? EquilConst.autoUnpairDelayLoopMs
            : EquilConst.autoUnpairDelayMs
        let work = DispatchWorkItem { [weak self] in self?.performAutoUnpairLocked() }
        autoUnpairWork = work
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs)), execute: work)
    }

    private func cancelAutoUnpairLocked() {
        autoUnpairWork?.cancel()
        autoUnpairWork = nil
    }

    private func performAutoUnpairLocked() {
        autoUnpairWork = nil
        guard boundToPump, !wizardActive else { return }

        // 有命令正在执行或刚结束不久 → 让位重排。
        if isExecutingCommand {
            scheduleAutoUnpairLocked()
            return
        }
        let idleMs = Date.now.timeIntervalSince(lastCmdFinishTime) * 1000
        if idleMs < Double(EquilConst.autoUnpairDelayMs) {
            scheduleAutoUnpairLocked()
            return
        }

        let unpair = makeUnPair(auto: true)
        link.writeCmd(unpair)
        _ = unpair.waitForCompletion(budgetMs: waitBudget(for: unpair))
        boundToPump = false

        // 解绑后必须主动断连：否则 GATT 悬挂至泵侧超时（约 9.6s），期间泵不广播。
        link.disconnect()
        EquilLog.info("auto-unpair after idle")
    }
}