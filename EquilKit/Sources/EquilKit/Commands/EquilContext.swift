import Foundation

/// 对照 AndroidAPS `EquilConst`：时序与阈值常量（保留原始注释中的实测依据）。
public enum EquilConst {

    /// 命令整体超时。
    public static let cmdTimeOut: Int64 = 300_000
    /// BLE 写入超时。
    public static let bleWriteTimeOut: Int64 = 20
    /// 命令完成后的链路释放延迟（"用完即走"）。
    public static let bleKeepAlive: Int64 = 2000
    /// 与上一命令完成的最小间隔：防背靠背发送被泵静默丢弃。
    public static let bleCmdMinInterval: Int64 = 500
    /// 定位循环命令专用最小间隔。
    public static let bleCmdFastInterval: Int64 = 200
    /// 断连后重连延迟。
    public static let bleReconnectDelay: Int64 = 2000
    /// 周期扫描间隔。
    public static let bleScanInterval: Int64 = 20_000
    /// 扫描超时。
    public static let bleScanTimeout: Int64 = 8000
    /// 电量追赶期扫描间隔。
    public static let bleScanIntervalFast: Int64 = 2000
    /// MTU 请求值。
    public static let bleMtuRequest = 512
    /// 大剂量速率枚举：0 = 1.5 U/min（默认）。
    public static let bolusRateDefault = 15
    /// 大剂量速率枚举：1 = 3.0 U/min。
    public static let bolusRateFast = 30
    /// 用完即走：最后命令后空闲多久自动解绑。
    public static let autoUnpairDelayMs: Int64 = 5000
    /// 闭环活跃期解绑延迟（复用绑定）。
    public static let autoUnpairDelayLoopMs: Int64 = 60_000

    /// 连接建立后到开始发送的延迟。
    public static let bleConnectDelay: Int64 = 10
    /// GATT 错误 133 的退避基数（Android 专有，iOS 仅作连接失败退避参考）。
    public static let bleError133Delay: Int64 = 100
    /// 单帧写入超时：超时重写，连续 3 次判定链路死亡。
    public static let bleWriteTimeoutMs: Int64 = 2000
    /// confirm 应答停滞监视窗口：正常应答 0.4–0.65s，1.5s 无收帧即判停滞。
    public static let confirmWatchMs: Int64 = 1500
    /// confirm 最多重写次数，超过走超时/自愈路径。
    public static let confirmMaxRewrite: Int = 2
    /// 官方固件最低支持版本。
    public static let supportLevel: Float = 1.0
    /// 推杆最大步数（回退/定位用）。
    public static let stepMax: Int = 32000
    /// 换药填充步数。
    public static let stepFill: Int = 160
    /// 排气步数。
    public static let stepAir: Int = 120
    /// 大剂量阈值步数（默认，对照 `EQUIL_BLOUS_THRESHOLD_STEP`）。
    public static let blousThresholdStep: Int = 1600
}

/// 全局命令计数器，对照 `BaseCmd.companion object` 的三个静态量。
///
/// AAPS 中是全局可变静态；此处保持同样语义，由调用方串行化命令执行
/// （AAPS 用 cmdLock 串行化），测试中可 `reset()`。
public enum EquilCounters {
    /// AES 域链路层分帧序号（每条消息 +1）。
    public static var reqIndex = 0
    /// AES 域命令内消息序号（每条消息 +1，起始 10）。
    public static var pumpReqIndex = 10
    /// 已处理应答的消息序号。
    public static var rspIndex = -1

    public static func reset() {
        reqIndex = 0
        pumpReqIndex = 10
        rspIndex = -1
    }
}

/// 命令运行所需的外部状态，替代 AAPS 的 `SP`(SharedPreferences) 与 `EquilManager` 写回。
///
/// 泵驱动层在接入 Trio 时提供实现；测试用 `InMemoryEquilSettings`。
public protocol EquilSettingsStore: AnyObject {
    /// 泵绑定后由 CmdPair 写回的设备标识（hex）。
    var equilDevices: String { get set }
    /// 泵绑定后由 CmdPair 写回的会话密码（hex）。
    var equilPassword: String { get set }
    /// 大剂量输注速率枚举（见 `EquilConst.bolusRateDefault`）。
    var bolusRate: Int { get set }
}

/// 内存实现，供单元测试与首轮联调使用。
public final class InMemoryEquilSettings: EquilSettingsStore {
    public var equilDevices: String
    public var equilPassword: String
    public var bolusRate: Int

    public init(equilDevices: String = "", equilPassword: String = "", bolusRate: Int = EquilConst.bolusRateDefault) {
        self.equilDevices = equilDevices
        self.equilPassword = equilPassword
        self.bolusRate = bolusRate
    }
}