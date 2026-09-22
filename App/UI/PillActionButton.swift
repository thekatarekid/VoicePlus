import AppKit
import SwiftUI

/// The footer uses an AppKit key view so recovery actions remain reachable when macOS's
/// Keyboard Navigation setting excludes ordinary buttons. Its label is still drawn by SwiftUI.
struct PillActionButton: NSViewRepresentable {
    let button: PillButton
    let perform: (PillActionKind) -> Void
    let onFocus: ((Bool, String) -> Void)?

    func makeNSView(context: Context) -> PillFooterButton { PillFooterButton() }

    func updateNSView(_ view: PillFooterButton, context: Context) {
        view.setAccessibilityLabel(button.label)
        view.setAccessibilityIdentifier(button.identifier)
        view.onPress = { perform(button.action) }
        view.onFocusChange = { onFocus?($0, "action.\(button.identifier)") }
    }

    static func dismantleNSView(_ view: PillFooterButton, coordinator: ()) {
        view.onFocusChange?(false)
    }
}

/// VoiceOver and AppKit keyboard focus own separate entries in the dwell-pause set.
/// A change in one focus system must not clear the other system's ownership.
struct PillActionAccessibilityFocus: ViewModifier {
    let element: String
    let report: ((Bool, String) -> Void)?
    @AccessibilityFocusState private var focused: Bool

    func body(content: Content) -> some View {
        content.accessibilityFocused($focused)
            .onChange(of: focused) { _, value in report?(value, element) }
            .onDisappear { report?(false, element) }
    }
}

final class PillFooterButton: NSButton {
    var onPress: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }

    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .exterior
        target = self
        action = #selector(press)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func press() { onPress?() }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: Tokens.Radius.control, yRadius: Tokens.Radius.control).fill()
    }
}
