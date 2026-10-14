import Foundation

/// 时间单位换算辅助（UI 模块本地副本）。
///
/// `EquilPumpKit` 与 `EquilPumpKitUI` 是两个独立的 framework，模块内的 internal 扩展无法跨模块访问，
/// 因此这里保留一份等价实现供 UI 侧使用（对照 MedtrumKit 把 Common 与 UI 放在同一 target 的做法）。
extension TimeInterval {
    static func hours(_ hours: Double) -> TimeInterval { hours * 3600 }
    static func minutes(_ minutes: Double) -> TimeInterval { minutes * 60 }
    static func minutes(_ minutes: Int) -> TimeInterval { Double(minutes) * 60 }
    static func seconds(_ seconds: Double) -> TimeInterval { seconds }

    var minutes: Double { self / 60 }
    var hours: Double { minutes / 60 }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}

/// `Bundle.main.bundleDisplayName` 在 MedtrumKit / LibreLoop 中各有 internal 实现，
/// 跨模块不可用，这里为本模块提供一份（用于 `\.appName` 环境值）。
extension Bundle {
    var bundleDisplayName: String {
        object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Trio"
    }
}
