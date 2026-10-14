import Foundation

/// 基础率表条目，对照 AndroidAPS `driver/definition/BasalScheduleEntry`。
///
/// AAPS 用 joda `Duration` 表示起始偏移；此处以距零点秒数替代（命令层只做数值比较与编码）。
public struct BasalScheduleEntry: Equatable {
    public let rate: Double
    /// 距零点秒数。
    public let startTimeSeconds: Int

    public init(rate: Double, startTimeSeconds: Int) {
        self.rate = rate
        self.startTimeSeconds = startTimeSeconds
    }
}

/// 基础率表，对照 AndroidAPS `driver/definition/BasalSchedule`。
public struct BasalSchedule: Equatable {

    public let entries: [BasalScheduleEntry]

    public init(entries: [BasalScheduleEntry]) {
        precondition(!entries.isEmpty, "Entries can not be empty")
        precondition(entries[0].startTimeSeconds == 0, "First basal schedule entry should have 0 offset")
        self.entries = entries
    }

    /// 取 offset（秒）处的速率：末条 startTime ≤ offset 的条目。
    public func rateAt(_ offsetSeconds: Int) -> Double {
        for entry in entries.reversed() where entry.startTimeSeconds <= offsetSeconds {
            return entry.rate
        }
        return entries[0].rate
    }

    /// 对照 `BasalSchedule.mapProfileToBasalSchedule`：24 段，每段一小时。
    public static func fromHourlyRates(_ rates: [Double]) -> BasalSchedule {
        precondition(rates.count >= 24, "需要 24 段基础率")
        var entries: [BasalScheduleEntry] = []
        for i in 0..<24 {
            entries.append(BasalScheduleEntry(rate: rates[i], startTimeSeconds: i * 3600))
        }
        return BasalSchedule(entries: entries)
    }
}