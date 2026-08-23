import UIKit
import KeyboardCore

/// Horizontal persona chips ("Plain", "Work email", …) edited in the companion app.
final class PersonaBar: UIScrollView {
    var onSelect: ((String) -> Void)?
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsHorizontalScrollIndicator = false
        stack.axis = .horizontal; stack.spacing = 6; stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor), stack.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor), stack.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor),
                                     stack.heightAnchor.constraint(equalTo: frameLayoutGuide.heightAnchor), heightAnchor.constraint(equalToConstant: 32)])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ picker: PersonaPicker) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for e in picker.entries {
            var cfg = e.id == picker.selectedID ? UIButton.Configuration.filled() : .gray()
            cfg.title = e.title; cfg.cornerStyle = .capsule; cfg.buttonSize = .small
            let b = UIButton(configuration: cfg)
            b.addAction(UIAction { [weak self] _ in self?.onSelect?(e.id); var p = picker; p.select(e.id); self?.set(p) }, for: .touchUpInside)
            stack.addArrangedSubview(b)
        }
    }
}
