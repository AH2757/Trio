import LoopKit
import LoopKitUI
import UIKit

/// Equil 储药器 HUD 视图。纯代码实现（不依赖 xib），对照 LoopKit 的 `ReservoirVolumeHUDView`。
///
/// 显示剩余药量（U）与最近一次同步时间；图标随剩余量变色（>25% 正常 / >10% 警告 / 其余错误）。
final class EquilReservoirView: BaseHUDView {

    /// Equil 储药器容量（U）。
    static let maxReservoirUnits: Double = 200

    override var orderPriority: HUDViewOrderPriority { 4 }

    private let iconView = UIImageView(image: UIImage(systemName: "drop.fill"))
    private let volumeLabel = UILabel()
    private let timeLabel = UILabel()

    private lazy var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private lazy var numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        volumeLabel.font = .preferredFont(forTextStyle: .headline)
        volumeLabel.textAlignment = .center
        volumeLabel.textColor = .label

        timeLabel.font = .preferredFont(forTextStyle: .caption2)
        timeLabel.textAlignment = .center
        timeLabel.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [iconView, volumeLabel, timeLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.heightAnchor.constraint(equalToConstant: 22),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2)
        ])

        update(level: nil, max: Self.maxReservoirUnits, at: nil)
    }

    /// 更新剩余量与时间。
    func update(level: Double?, max: Double, at date: Date?) {
        guard let level = level, max > 0 else {
            volumeLabel.text = "–"
            timeLabel.text = nil
            iconView.tintColor = stateColors?.unknown ?? .secondaryLabel
            accessibilityValue = nil
            return
        }

        let units = numberFormatter.string(from: level as NSNumber) ?? "0"
        volumeLabel.text = String(
            format: String(localized: "%@U", comment: "Format string for reservoir volume"),
            units
        )
        timeLabel.text = date.map { timeFormatter.string(from: $0) }

        let fraction = level / max
        switch fraction {
        case let x where x > 0.25:
            iconView.tintColor = stateColors?.normal ?? .systemBlue
        case let x where x > 0.10:
            iconView.tintColor = stateColors?.warning ?? .systemOrange
        default:
            iconView.tintColor = stateColors?.error ?? .systemRed
        }

        let timeText = date.map { timeFormatter.string(from: $0) } ?? ""
        accessibilityValue = String(
            format: String(
                localized: "%1$@ units remaining at %2$@",
                comment: "Accessibility format string for reservoir volume and time"
            ),
            units, timeText
        )
    }
}