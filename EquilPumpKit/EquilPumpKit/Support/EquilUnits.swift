import Foundation

/// 时间单位换算辅助（LoopKit 未提供，对照 MedtrumKit `Common/TimeInterval.swift`）。
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