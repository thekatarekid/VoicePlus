import AppKit

// V5 L1 · the ambient mode in the one menu (menu bar glyph and notch open the same NSMenu): a row
// that names the mode, with a segmented Off · Listen & note · Listen & act control under it.

@MainActor
public enum AmbientModeMenu {
    public static let identifier = NSUserInterfaceItemIdentifier("ambient.mode")

    /// The menu row title ("Ambient · Listen & note").
    public static func title(_ mode: AmbientMode) -> String { "Ambient · \(mode.title)" }

    public static func item(controller: AmbientModeController, onChange: (() -> Void)? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title(controller.mode), action: nil, keyEquivalent: "")
        item.identifier = identifier
        item.view = AmbientModeMenuView(controller: controller, onChange: onChange)
        return item
    }
}

/// Label + segmented control, sized like a menu row.
final class AmbientModeMenuView: NSView {
    private let controller: AmbientModeController
    private let onChange: (() -> Void)?
    let label = NSTextField(labelWithString: "")
    let segmented: NSSegmentedControl

    init(controller: AmbientModeController, onChange: (() -> Void)?) {
        self.controller = controller
        self.onChange = onChange
        segmented = NSSegmentedControl(labels: AmbientMode.allCases.map(\.title), trackingMode: .selectOne,
                                       target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 52))
        segmented.target = self
        segmented.action = #selector(changed(_:))
        segmented.setAccessibilityLabel("Ambient listening")
        segmented.identifier = NSUserInterfaceItemIdentifier("ambient.mode.segmented")
        label.font = .menuFont(ofSize: 0)
        label.textColor = .secondaryLabelColor
        for v in [label, segmented] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            segmented.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
            segmented.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            segmented.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    func refresh() {
        let mode = controller.mode
        label.stringValue = AmbientModeMenu.title(mode)
        segmented.selectedSegment = AmbientMode.allCases.firstIndex(of: mode) ?? 0
    }

    @objc func changed(_ sender: NSSegmentedControl) {
        let i = sender.selectedSegment
        guard AmbientMode.allCases.indices.contains(i) else { return }
        controller.set(AmbientMode.allCases[i])
        refresh()
        onChange?()
    }
}
