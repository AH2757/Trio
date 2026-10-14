import Foundation
import LoopKit

/// 微泰 Equil 泵的用户可见告警，对接 LoopKit `Alert` / `AlertResponder`。
///
/// 对照 MedtrumKit `MedtrumAlert`。告警来源有两类：
/// - 泵端事件码（广播 [25..27] 或历史 type/level/parm）经 `EquilAlarm` 分类；
/// - 遥测阈值（低电量、低药量）由驱动层在每次同步后判定。
///
/// 告警的"确认"动作（`acknowledgeAlert`）在本驱动中不需要向泵回写——
/// 泵端告警的清除由换药/复位流程完成，因此确认仅通知 LoopKit 停止展示。
public enum EquilAlert {

    /// 低药量（剩余药量低于阈值）。
    case lowReservoir(level: Double)
    /// 低电量（电量低于阈值）。
    case lowBattery(percent: Double)
    /// 堵管（推杆阻力超阈值）。
    case occlusion
    /// 推杆回退（(4,8,0)）：换药/药尽/电池耗尽的自动回退。
    case pushrodRewind
    /// 泵异常断电重启（(5,1,0)）。
    case powerLoss
    /// 其它泵端故障（未知事件码）。
    case pumpFault(message: String)

    /// LoopKit `Alert.Identifier.managerIdentifier`。
    public static let managerIdentifier = "Equil"

    /// 由泵端广播/历史事件码分类出的告警映射。
    public static func from(_ alarm: EquilAlarm) -> EquilAlert {
        switch alarm.kind {
        case .lowReservoir: return .lowReservoir(level: 0)
        case .lowBattery: return .lowBattery(percent: 0)
        case .occlusion: return .occlusion
        case .pushrodRewind: return .pushrodRewind
        case .powerLoss: return .powerLoss
        case .unknown: return .pumpFault(message: alarm.message)
        }
    }

    /// 稳定告警标识（同一类型重复触发时 LoopKit 会去重/替换）。
    public var alertIdentifier: Alert.AlertIdentifier {
        switch self {
        case .lowReservoir: return "equil.low-reservoir"
        case .lowBattery: return "equil.low-battery"
        case .occlusion: return "equil.occlusion"
        case .pushrodRewind: return "equil.pushrod-rewind"
        case .powerLoss: return "equil.power-loss"
        case .pumpFault: return "equil.fault"
        }
    }

    /// 对应 LoopKit 泵事件告警类型（写入历史用）。
    public var pumpAlarmType: PumpAlarmType {
        switch self {
        case .lowReservoir: return .lowInsulin
        case .lowBattery: return .lowPower
        case .occlusion: return .occlusion
        case .pushrodRewind: return .other("pushrodRewind")
        case .powerLoss: return .noPower
        case .pumpFault: return .other("equilFault")
        }
    }

    public var identifier: Alert.Identifier {
        Alert.Identifier(managerIdentifier: Self.managerIdentifier, alertIdentifier: alertIdentifier)
    }

    /// 告警内容。
    public var content: Alert.Content {
        switch self {
        case let .lowReservoir(level):
            let body = level > 0
                ? String(format: "泵内剩余药量不足（%.1f U），请尽快更换储药器。", level)
                : "泵内剩余药量不足，请尽快更换储药器。"
            return Alert.Content(title: "药量不足", body: body, acknowledgeActionButtonLabel: "知道了")
        case let .lowBattery(percent):
            let body = percent > 0
                ? String(format: "泵电量仅剩 %.0f%%，请及时充电。", percent)
                : "泵电量过低，请及时充电。"
            return Alert.Content(title: "电量不足", body: body, acknowledgeActionButtonLabel: "知道了")
        case .occlusion:
            return Alert.Content(title: "管路堵塞", body: "泵检测到堵管，输注已停止，请检查管路与输注部位。", acknowledgeActionButtonLabel: "知道了")
        case .pushrodRewind:
            return Alert.Content(title: "推杆已回退", body: "泵推杆已回退，通常发生在换药或药尽后，请确认泵状态。", acknowledgeActionButtonLabel: "知道了")
        case .powerLoss:
            return Alert.Content(title: "泵异常断电", body: "泵检测到异常断电并已重启，请核对泵时间与运行状态。", acknowledgeActionButtonLabel: "知道了")
        case let .pumpFault(message):
            return Alert.Content(title: "泵告警", body: message.isEmpty ? "泵上报了未知告警，请检查泵。" : message, acknowledgeActionButtonLabel: "知道了")
        }
    }

    /// 触发方式：泵端告警立即触发。
    public var trigger: Alert.Trigger { .immediate }

    public var alert: Alert {
        let content = self.content
        return Alert(
            identifier: identifier,
            foregroundContent: content,
            backgroundContent: content,
            trigger: trigger
        )
    }
}