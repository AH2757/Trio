import Foundation

/// 轻量日志出口，替代 AAPS 的 `AAPSLogger`。
///
/// 泵驱动层接入 Trio 时把 `handler` 指向 Trio 的日志系统；测试中可留空。
public enum EquilLog {
    public enum Level: String {
        case debug = "D"
        case info = "I"
        case warn = "W"
        case error = "E"
    }

    public static var handler: ((Level, String) -> Void)?

    public static func debug(_ message: @autoclosure () -> String) { handler?(.debug, message()) }
    public static func info(_ message: @autoclosure () -> String) { handler?(.info, message()) }
    public static func warn(_ message: @autoclosure () -> String) { handler?(.warn, message()) }
    public static func error(_ message: @autoclosure () -> String) { handler?(.error, message()) }
}

/// 传输层错误，对照 AAPS `BluetoothConnectionState` 与 GATT 回调状态。
public enum EquilTransportError: Error, Equatable {
    /// 连接建立失败（Android GATT 133 / iOS 连接超时）。
    case connectFailed
    /// 对端主动断开（Android status 19）。
    case remoteTerminated
    /// 未找到目标服务/特征。
    case serviceNotFound
    /// CCC 描述符订阅失败。
    case notifySubscriptionFailed
    /// 扫描超时。
    case scanTimeout
    /// 其它。
    case other(String)
}

/// 传输层事件回调。链路状态机（`EquilLinkController`）实现此协议。
///
/// 把 Core Bluetooth 的具体回调抽象成与平台无关的事件，链路逻辑因此可在
/// 无蓝牙环境下用假传输层做单元测试。
public protocol EquilTransportDelegate: AnyObject {
    /// 扫描到目标设备（已按标识/名称匹配）。
    func transportDidDiscover(advertisement: [UInt8], rssi: Int)
    /// GATT 连接建立。
    func transportDidConnect()
    /// 服务发现完成。`hasTargetService=false` 表示未找到 f000 服务，应断开重连。
    func transportDidDiscoverServices(hasTargetService: Bool)
    /// 通知通道就绪（写入了 CCC，或按画像跳过 CCC）。
    func transportIsReady()
    /// 单帧写入完成（对应 Android `onCharacteristicWrite`）。
    func transportDidWrite()
    /// 收到一帧（对应 `onCharacteristicChanged` / `onCharacteristicRead`）。
    func transportDidReceive(_ data: [UInt8])
    /// 连接断开。
    func transportDidDisconnect(error: EquilTransportError?)
    /// MTU 协商结果。
    func transportDidUpdateMtu(_ mtu: Int)
}

/// BLE 传输抽象。iOS 实现见 `CoreBluetoothTransport`；测试用 `FakeEquilTransport`。
public protocol EquilTransport: AnyObject {
    var delegate: EquilTransportDelegate? { get set }

    /// 目标外设标识。iOS 无 MAC，用 Core Bluetooth 的 `UUID`（每台手机唯一）。
    /// 首配时为空，靠 `targetNamePrefix` 扫描匹配。
    var targetIdentifier: UUID? { get set }
    /// 首配时按广播名匹配（`Equil - <SN>`）。
    var targetNamePrefix: String? { get set }
    /// 连接后是否跳过 CCC 订阅（官方域画像）。true 时不写 2902，直接置就绪。
    var skipCccSubscription: Bool { get set }
    /// 写入是否要求 ATT 应答（官方域用 withResponse，其余用 withoutResponse）。
    var writeWithResponse: Bool { get set }

    var isConnected: Bool { get }

    func startScan()
    func stopScan()
    func connect()
    func disconnect()
    func write(_ bytes: [UInt8])
    func setNotify(_ enabled: Bool)
}

/// 可取消的延时任务。用于把 AAPS `Handler.sendEmptyMessageDelayed` 系列定时器
/// 映射到 Swift，且可在测试中替换实现。
public final class EquilTimer {

    private let queue: DispatchQueue
    private var workItem: DispatchWorkItem?

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    public var isScheduled: Bool {
        guard let item = workItem else { return false }
        return !item.isCancelled
    }

    public func schedule(_ milliseconds: Int64, _ block: @escaping () -> Void) {
        cancel()
        let item = DispatchWorkItem(block: block)
        workItem = item
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(milliseconds)), execute: item)
    }

    public func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}