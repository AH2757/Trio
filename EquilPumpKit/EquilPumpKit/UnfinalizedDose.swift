import Foundation
import LoopKit

/// 未定稿剂量（大剂量/基础率/暂停/恢复），对照 MedtrumKit `UnfinalizedDose`。
///
/// 语义：命令下发成功后立即以"进行中"剂量写入 LoopKit 事件流；实际输注量由
/// 后续进度回报（`deliveredUnits`）补齐。`toDoseEntry(isMutable:)` 区分可变/定稿形态。
public class UnfinalizedDose {
    public typealias RawValue = [String: Any]

    public let type: DoseType
    public let startDate: Date
    public let estimatedEndDate: Date
    public let value: Double
    public var deliveredUnits: Double = 0
    public let insulinType: InsulinType?
    public let automatic: Bool

    public init(units: Double, duration: TimeInterval, activationType: BolusActivationType, insulinType: InsulinType?) {
        type = .bolus
        value = units
        startDate = Date.now
        estimatedEndDate = Date.now.addingTimeInterval(duration)
        self.insulinType = insulinType
        automatic = activationType.isAutomatic
    }

    public init(basalRate: Double, insulinType: InsulinType?, startDate: Date = Date.now) {
        type = .basal
        value = basalRate
        self.startDate = startDate
        estimatedEndDate = startDate
        self.insulinType = insulinType
        automatic = false
    }

    public init(tempRate: Double, duration: TimeInterval, insulinType: InsulinType?, automatic: Bool) {
        type = .tempBasal
        value = tempRate
        startDate = Date.now
        self.insulinType = insulinType
        estimatedEndDate = startDate.addingTimeInterval(duration)
        self.automatic = automatic
    }

    public init(suspendStartTime: Date) {
        type = .suspend
        value = 0
        startDate = suspendStartTime
        estimatedEndDate = suspendStartTime
        automatic = false
        insulinType = nil
    }

    public init(resumeStartTime: Date, insulinType: InsulinType?) {
        type = .resume
        value = 0
        startDate = resumeStartTime
        estimatedEndDate = resumeStartTime
        self.insulinType = insulinType
        automatic = false
    }

    public init?(rawValue: RawValue) {
        guard let rawType = rawValue["type"] as? DoseType.RawValue,
              let type = DoseType(rawValue: rawType),
              let value = rawValue["value"] as? Double,
              let startDate = rawValue["startDate"] as? Date,
              let estimatedEndDate = rawValue["estimatedEndDate"] as? Date,
              let automatic = rawValue["automatic"] as? Bool
        else { return nil }

        self.type = type
        self.value = value
        self.startDate = startDate
        self.estimatedEndDate = estimatedEndDate
        self.deliveredUnits = rawValue["deliveredUnits"] as? Double ?? 0
        self.automatic = automatic
        if let rawInsulinType = rawValue["insulinType"] as? InsulinType.RawValue {
            insulinType = InsulinType(rawValue: rawInsulinType)
        } else {
            insulinType = nil
        }
    }

    public var rawValue: RawValue {
        var raw: RawValue = [:]
        raw["type"] = type.rawValue
        raw["value"] = value
        raw["startDate"] = startDate
        raw["estimatedEndDate"] = estimatedEndDate
        raw["deliveredUnits"] = deliveredUnits
        raw["insulinType"] = insulinType?.rawValue
        raw["automatic"] = automatic
        return raw
    }

    public func toDoseEntry(isMutable: Bool = false, useEstimatedEndDate: Bool = false, endDate: Date = Date.now) -> DoseEntry {
        switch type {
        case .bolus:
            var resolvedEnd = isMutable || useEstimatedEndDate ? estimatedEndDate : endDate
            if useEstimatedEndDate, resolvedEnd > Date.now {
                // 定稿的大剂量结束时间不能在未来。
                resolvedEnd = Date.now
            }
            return DoseEntry(
                type: .bolus,
                startDate: startDate,
                endDate: resolvedEnd,
                value: value.rounded(toPlaces: 2),
                unit: .units,
                deliveredUnits: isMutable ? nil : deliveredUnits.rounded(toPlaces: 2),
                insulinType: insulinType,
                automatic: automatic,
                isMutable: isMutable
            )

        case .basal:
            return DoseEntry(
                type: .basal,
                startDate: startDate,
                value: EquilPumpManager.roundBasalRate(value),
                unit: .unitsPerHour,
                insulinType: insulinType
            )

        case .tempBasal:
            let actualEnd = isMutable ? estimatedEndDate : min(endDate, estimatedEndDate)
            let duration = actualEnd.timeIntervalSince(startDate)
            return DoseEntry(
                type: .tempBasal,
                startDate: startDate,
                endDate: actualEnd,
                value: value,
                unit: .unitsPerHour,
                deliveredUnits: isMutable ? nil : EquilPumpManager.roundBasalRate(value * (duration / .hours(1))),
                insulinType: insulinType,
                automatic: automatic,
                isMutable: isMutable
            )

        case .suspend:
            return DoseEntry(suspendDate: startDate, automatic: automatic)

        case .resume:
            return DoseEntry(resumeDate: startDate, insulinType: insulinType, automatic: automatic)

        default:
            // 其余剂量类型（如 .basal 变体）不由此模型产生。
            return DoseEntry(type: .basal, startDate: startDate, value: value, unit: .unitsPerHour, insulinType: insulinType)
        }
    }
}