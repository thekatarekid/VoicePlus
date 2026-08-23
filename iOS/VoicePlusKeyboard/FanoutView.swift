import UIKit
import KeyboardCore

/// Numbered alternates for the lowest-confidence word (same fan-out as the Mac). Tap a number
/// or say it in the next utterance; hidden when there is nothing to repair.
final class FanoutView: UIView {
    var onPick: ((Int) -> Void)?
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .horizontal; stack.spacing = 6; stack.distribution = .fillProportionally
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor), heightAnchor.constraint(equalToConstant: 36)])
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ fan: KeyboardRepairFanout?) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let fan else { isHidden = true; return }
        isHidden = false
        for item in fan.items {
            var cfg = UIButton.Configuration.tinted()
            cfg.title = "\(item.number) \(item.text)"; cfg.cornerStyle = .capsule
            let b = UIButton(configuration: cfg); b.tag = item.number
            b.addAction(UIAction { [weak self] _ in self?.onPick?(item.number) }, for: .touchUpInside)
            stack.addArrangedSubview(b)
        }
    }
}
