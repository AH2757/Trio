import Foundation
import LoopKit

/// 构造 LoopKit 泵事件（对照 MedtrumKit `NewPumpEvent.swift`）。
public extension NewPumpEvent {

    private static let dateFormatter = ISO8601DateFormatter()

    static func bolus(dose: DoseEntry) -> NewPumpEvent {
        NewPumpEvent(
            date: dose.startDate,
            dose: dose,
            raw: "bolus \(dose.programmedUnits) \(dateFormatter.string(from: dose.startDate))".data(using: .utf8) ?? Data(),
            title: "Bolus"
        )
    }

    static func bolus(unfinalizedDose: UnfinalizedDose) -> NewPumpEvent {
        NewPumpEvent.bolus(dose: unfinalizedDose.toDoseEntry(isMutable: true))
    }

    static func tempBasal(dose: DoseEntry) -> NewPumpEvent {
        NewPumpEvent(
            date: dose.startDate,
            dose: dose,
            raw: "tempBasal \(dose.unitsPerHour) \(dateFormatter.string(from: dose.startDate))".data(using: .utf8) ?? Data(),
            title: "Temp Basal"
        )
    }

    static func basal(dose: DoseEntry) -> NewPumpEvent {
        NewPumpEvent(
            date: dose.startDate,
            dose: dose,
            raw: "basal \(dateFormatter.string(from: dose.startDate))".data(using: .utf8) ?? Data(),
            title: "Basal"
        )
    }

    static func resume(dose: DoseEntry) -> NewPumpEvent {
        NewPumpEvent(
            date: dose.startDate,
            dose: dose,
            raw: "resume \(dateFormatter.string(from: dose.startDate))".data(using: .utf8) ?? Data(),
            title: "Resume"
        )
    }

    static func suspend(dose: DoseEntry) -> NewPumpEvent {
        NewPumpEvent(
            date: dose.startDate,
            dose: dose,
            raw: "suspend \(dateFormatter.string(from: dose.startDate))".data(using: .utf8) ?? Data(),
            title: "Suspended"
        )
    }

    /// 换泵（配对新泵时重置活动泵标识）。
    static func replacedPump(date: Date = Date.now) -> NewPumpEvent {
        NewPumpEvent(
            date: date,
            dose: nil,
            raw: "PUMP_REPLACE \(dateFormatter.string(from: date))".data(using: .utf8) ?? Data(),
            title: "Pump replace",
            type: .replaceComponent(componentType: .pump),
            alarmType: nil
        )
    }

    /// 泵报警事件（堵管/低电量/低药量等）。
    static func alarm(_ alarm: EquilAlarm) -> NewPumpEvent {
        NewPumpEvent(
            date: alarm.occurredAt,
            dose: nil,
            raw: alarm.message.data(using: .utf8) ?? Data(),
            title: alarm.message,
            type: .alarm,
            alarmType: alarm.pumpAlarmType
        )
    }
}

extension EquilAlarm {
    var pumpAlarmType: PumpAlarmType {
        switch kind {
        case .occlusion: return .occlusion
        case .lowBattery: return .lowPower
        case .lowReservoir: return .lowInsulin
        case .pushrodRewind: return .other("pushrodRewind")
        case .powerLoss: return .noPower
        case .unknown: return .other("equilAlarm")
        }
    }
}