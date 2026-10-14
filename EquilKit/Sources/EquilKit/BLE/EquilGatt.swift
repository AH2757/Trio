import Foundation

/// Equil 泵的 GATT 标识，对照 AndroidAPS `ble/GattAttributes.kt`。
///
/// 泵只暴露一个服务 f000 与一个特征 f001（读/写/通知共用同一 UUID），
/// 这是 Nordic UART 风格的极简服务，无厂商私有描述符。
public enum EquilGatt {

    /// 主服务。
    public static let serviceRadio = "0000F000-0000-1000-8000-00805F9B34FB"
    /// 通知特征（泵→App）。
    public static let characteristicNotify = "0000F001-0000-1000-8000-00805F9B34FB"
    /// 写入特征（App→泵），与通知特征同 UUID。
    public static let characteristicWrite = "0000F001-0000-1000-8000-00805F9B34FB"
    /// CCC 描述符。
    public static let characteristicConfigDescriptor = "00002902-0000-1000-8000-00805F9B34FB"

    /// 广播名形如 `Equil - <SN>`，首配时用于发现设备。
    public static let advertisedNamePrefix = "Equil"
    /// 默认 ATT MTU（iOS 会自行协商，通常可达 185+）。
    public static let defaultMtu = 23
}