import AppKit
import Engine
import Shared
import SwiftUI

/// Pure geometry for the correction highlight: the underline bar sits along the bottom of the
/// corrected word's AX rect; the hover card hangs beneath it (or above when there is no room).
public struct CorrectionOverlayModel: Equatable, Sendable {
    public static let underlineHeight: CGFloat = 3
    public static let cardHeight: CGFloat = 26
    public static let gap: CGFloat = 3

    public var entry: CorrectionEntry
    public var wordRect: CGRect
    public var phase: CorrectionHighlightPhase
    public var hovered: Bool

    public init(entry: CorrectionEntry, wordRect: CGRect, phase: CorrectionHighlightPhase = .shimmer, hovered: Bool = false) {
        self.entry = entry; self.wordRect = wordRect; self.phase = phase; self.hovered = hovered
    }

    /// Panel frame (AppKit coords). Covers the word so hover works, plus the card when hovered.
    public func frame(in screen: CGRect) -> CGRect {
        var f = wordRect.insetBy(dx: -2, dy: -2)
        if hovered {
            let w = max(f.width, CGFloat(entry.hoverLabel.count) * 7 + 70)
            let below = f.minY - Self.gap - Self.cardHeight >= screen.minY
            f = below ? CGRect(x: f.minX, y: f.minY - Self.gap - Self.cardHeight, width: w, height: f.height + Self.gap + Self.cardHeight)
                      : CGRect(x: f.minX, y: f.minY, width: w, height: f.height + Self.gap + Self.cardHeight)
        }
        f.origin.x = min(max(f.minX, screen.minX), screen.maxX - f.width)
        return f
    }

    /// Card is above the word when the frame had to flip.
    public func cardIsAbove(in screen: CGRect) -> Bool { wordRect.minY - 2 - Self.gap - Self.cardHeight < screen.minY }
    public var isVisible: Bool { phase != .gone || hovered }
}

/// Shows the shimmer/underline on a corrected word, "was: …" on hover, and one-tap revert.
/// Anchored through `WordRectProvider` (AX `kAXBoundsForRangeParameterizedAttribute`, like the
/// repair fan-out); without a rect (no AX) nothing is drawn — the menu list still has the entry.
public final class CorrectionOverlayController {
    public let ledger: CorrectionLedger
    public var rectProvider: WordRectProvider
    public var revertSink: ReplaceRangeSink?
    public var isEnabled: () -> Bool = { true }
    private let panel: NSPanel
    private let state = CorrectionOverlayState()
    private var timer: Timer?
    private var shownAt: Date?
    public private(set) var model: CorrectionOverlayModel?
    public var onReverted: ((CorrectionEntry) -> Void)?

    public init(ledger: CorrectionLedger, rectProvider: WordRectProvider = AXWordRectProvider()) {
        self.ledger = ledger
        self.rectProvider = rectProvider
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar + 1
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: CorrectionOverlayView(state: state, onHover: { [weak self] in self?.setHovered($0) },
                                                                          onRevert: { [weak self] in self?.revertShown() }))
        ledger.onEntry = { [weak self] entry in DispatchQueue.main.async { self?.show(entry) } }
    }

    /// Show the highlight for an applied correction. Returns false when nothing can be drawn.
    @discardableResult
    public func show(_ entry: CorrectionEntry) -> Bool {
        guard entry.status == .applied, isEnabled(), let rect = rectProvider.wordRect(utf16Range: entry.range) else { return false }
        shownAt = Date()
        model = CorrectionOverlayModel(entry: entry, wordRect: rect)
        render()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        return true
    }

    func tick() {
        guard var m = model, let t0 = shownAt else { return }
        m.phase = CorrectionHighlightPhase.at(Date().timeIntervalSince(t0))
        model = m
        if !m.isVisible { hide() } else { render() }
    }

    func setHovered(_ hovered: Bool) {
        guard var m = model else { return }
        m.hovered = hovered
        model = m
        if !m.isVisible { hide() } else { render() }
    }

    @discardableResult
    public func revertShown() -> RepairReplaceOutcome? {
        guard let m = model, let sink = revertSink else { return nil }
        let outcome = ledger.revert(m.entry, via: sink)
        if outcome.succeeded, let e = ledger.entry(id: m.entry.id) { onReverted?(e) }
        hide()
        return outcome
    }

    public func hide() {
        timer?.invalidate(); timer = nil
        model = nil
        state.model = nil
        panel.orderOut(nil)
    }

    public var isVisible: Bool { panel.isVisible }

    private func render() {
        guard let m = model else { return }
        let screen = (NSScreen.screens.first { $0.frame.intersects(m.wordRect) } ?? NSScreen.main)?.visibleFrame ?? .zero
        state.model = m
        state.cardAbove = m.cardIsAbove(in: screen)
        panel.setFrame(m.frame(in: screen), display: true)
        panel.orderFrontRegardless()
    }
}

final class CorrectionOverlayState: ObservableObject {
    @Published var model: CorrectionOverlayModel?
    @Published var cardAbove = false
}

struct CorrectionOverlayView: View {
    @ObservedObject var state: CorrectionOverlayState
    var onHover: (Bool) -> Void
    var onRevert: () -> Void

    var body: some View {
        VStack(spacing: CorrectionOverlayModel.gap) {
            if let m = state.model {
                if m.hovered && state.cardAbove { card(m) }
                ZStack(alignment: .bottom) {
                    Color.clear
                    Rectangle()
                        .fill(m.phase == .shimmer ? AnyShapeStyle(LinearGradient(colors: [.accentColor.opacity(0.2), .accentColor, .accentColor.opacity(0.2)], startPoint: .leading, endPoint: .trailing))
                                                   : AnyShapeStyle(Color.accentColor.opacity(0.8)))
                        .frame(height: CorrectionOverlayModel.underlineHeight)
                        .animation(.easeInOut(duration: CorrectionHighlightPhase.shimmerSeconds), value: m.phase)
                }
                .frame(height: m.wordRect.height + 4)
                .contentShape(Rectangle())
                .onHover(perform: onHover)
                .accessibilityIdentifier("correction.underline.\(m.phase)")
                if m.hovered && !state.cardAbove { card(m) }
            }
        }
    }

    private func card(_ m: CorrectionOverlayModel) -> some View {
        HStack(spacing: 8) {
            Text(m.entry.hoverLabel).font(.system(size: 12)).lineLimit(1)
            Button(action: onRevert) { Label("Put back", systemImage: "arrow.uturn.backward") }
                .buttonStyle(.borderless).font(.system(size: 11))
                .accessibilityLabel("Revert to \(m.entry.was)")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: CorrectionOverlayModel.cardHeight)
        .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1)))
        .onHover(perform: onHover)
    }
}
