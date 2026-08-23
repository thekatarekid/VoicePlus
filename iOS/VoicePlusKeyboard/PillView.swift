import UIKit
import KeyboardCore

/// Hold-to-talk pill: press-and-hold starts, release stops. Draws the `KeyboardPillModel`
/// bars so the waveform logic stays in KeyboardCore.
final class PillView: UIControl {
    var onPress: ((Bool) -> Void)?
    private let label = UILabel()
    private let bars = UIStackView()
    private var barViews: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 32; backgroundColor = .systemGray5; clipsToBounds = true
        label.textAlignment = .center; label.font = .systemFont(ofSize: 17, weight: .medium)
        label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.6
        bars.axis = .horizontal; bars.spacing = 3; bars.alignment = .center; bars.distribution = .fillEqually
        barViews = (0..<12).map { _ in let v = UIView(); v.backgroundColor = .white; v.layer.cornerRadius = 1.5; v.heightAnchor.constraint(equalToConstant: 4).isActive = true; return v }
        barViews.forEach(bars.addArrangedSubview)
        for v in [label, bars] { v.translatesAutoresizingMaskIntoConstraints = false; v.isUserInteractionEnabled = false; addSubview(v) }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -6),
            bars.centerXAnchor.constraint(equalTo: centerXAnchor), bars.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6), bars.widthAnchor.constraint(equalToConstant: 90),
        ])
        addTarget(self, action: #selector(down), for: .touchDown)
        addTarget(self, action: #selector(up), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func down() { onPress?(true) }
    @objc private func up() { onPress?(false) }

    func apply(_ m: KeyboardPillModel) {
        label.text = m.label
        switch m.tint {
        case .neutral: backgroundColor = .systemGray5; label.textColor = .label
        case .listening: backgroundColor = .systemRed; label.textColor = .white
        case .proxying: backgroundColor = .systemIndigo; label.textColor = .white
        case .landed: backgroundColor = .systemGreen; label.textColor = .white
        case .error: backgroundColor = .systemOrange; label.textColor = .white
        }
        let heights = KeyboardPillModel.bars(level: m.tint == .listening ? m.level : 0)
        bars.isHidden = m.tint != .listening
        for (v, h) in zip(barViews, heights) { v.transform = CGAffineTransform(scaleX: 1, y: CGFloat(1 + h * 3)) }
    }
}
