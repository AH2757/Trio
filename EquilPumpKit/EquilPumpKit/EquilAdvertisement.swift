import Foundation

/// 泵周期广播（28 字节）解码，对照 AndroidAPS `EquilManager.decodeData`。
///
/// 广播是"用完即走"架构下唯一不需要绑定即可获取的遥测：电量、药量、当前基础率、
/// 历史游标与事件码。AAPS v39 起停用一切主动轮询，电池/药量/运行模式全部由此被动解码。
public struct EquilAdvertisement: Equatable {

    /// 泵本地时间。
    public let pumpDate: Date
    /// 电量百分比（0–100）。
    public let batteryPercent: Double
    /// 剩余药量（U）。
    public let reservoirUnits: Double
    /// 当前基础率（U/h）。
    public let basalRateUnitsPerHour: Double
    /// 泵端历史游标（领先本机已同步游标即有新条目）。
    public let historyIndex: Int
    /// 事件端口（0 表示无事件）。
    public let eventPort: Int
    public let eventLevel: Int
    public let eventParam: Int

    /// 对照 `EquilManager.decodeData`：字段索引 11..27，速率换算 ×0.00625。
    public static func parse(_ bytes: [UInt8]) -> EquilAdvertisement? {
        guard bytes.count >= 28 else { return nil }

        var comps = DateComponents()
        comps.year = Int(bytes[11]) + 2000
        comps.month = Int(bytes[12])
        comps.day = Int(bytes[13])
        comps.hour = Int(bytes[14])
        comps.minute = Int(bytes[15])
        comps.second = Int(bytes[16])
        let date = Calendar.current.date(from: comps) ?? Date()

        let rateRaw = (Int(bytes[20]) << 8) | Int(bytes[19])
        let historyIndex = (Int(bytes[24]) << 8) | Int(bytes[23])

        return EquilAdvertisement(
            pumpDate: date,
            batteryPercent: Double(bytes[17]),
            reservoirUnits: Double(bytes[18]),
            basalRateUnitsPerHour: Double(rateRaw) * 0.00625,
            historyIndex: historyIndex,
            eventPort: Int(bytes[25]),
            eventLevel: Int(bytes[26]),
            eventParam: Int(bytes[27])
        )
    }

    /// 广播事件码 → 驱动层报警。对照 `EquilManager.decodeData` 与 `pushrodRetractCauseResId`。
    ///
    /// 只识别两个有明确语义的事件码；其余非零端口按堵管告警处理（与 AAPS 默认分类一致）。
    public var alarm: EquilAlarm? {
        guard eventPort != 0 else { return nil }
        let kind: EquilAlarm.Kind
        let message: String
        if eventPort == 4 && eventLevel == 8 && eventParam == 0 {
            kind = .pushrodRewind
            message = "推杆回退"
        } else if eventPort == 5 && eventLevel == 1 && eventParam == 0 {
            kind = .powerLoss
            message = "泵异常断电重启"
        } else {
            kind = .occlusion
            message = "泵告警（端口 \(eventPort) 级别 \(eventLevel) 参数 \(eventParam)）"
        }
        return EquilAlarm(
            kind: kind,
            code: (eventPort << 16) | (eventLevel << 8) | eventParam,
            occurredAt: pumpDate,
            message: message
        )
    }
}