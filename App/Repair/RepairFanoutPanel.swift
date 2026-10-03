import AppKit
import ApplicationServices
import Engine
import Shared
import SwiftUI

/// Reads a word's on-screen rect through Accessibility (`kAXBoundsForRangeParameterizedAttribute`
/// on the focused element). Needs the Accessibility permission; returns nil otherwise so the
/// panel falls back to the caret / mouse position.
public protocol WordRectProvider: AnyObject {
    /// `range` is UTF-16 in the focused element's value; result is in AppKit screen coordinates.
    func wordRect(utf16Range: Range<Int>) -> CGRect?
}

public final class AXWordRectProvider: WordRectProvider {
    public init() {}

    public func wordRect(utf16Range: Range<Int>) -> CGRect? {
        // K18 — system-wide focus through the guard (own pid off-main → refuse).
        guard let element = AXGuard.focusedElement() else { return nil }
        var cfRange = CFRange(location: utf16Range.lowerBound, length: utf16Range.count)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var bounds: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &bounds)
        guard err == .success, let b = bounds else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(b as! AXValue, .cgRect, &rect), rect.width > 0 else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return RepairFanoutModel.appKitRect(fromAX: rect, primaryScreenHeight: primaryHeight)
    }
}

/// T4 — non-activating panel that fans the numbered alternates out beneath a landed word.
/// Click a row or say "number two" / "no, ‹word›" to pick; picks go to the `RepairSession`.
public final class RepairFanoutPanel {
    public let session: RepairSession
    public var rectProvider: WordRectProvider
    private let panel: NSPanel
    private let host: NSHostingView<RepairFanoutView>
    private let state = RepairFanoutState()
    public private(set) var model: RepairFanoutModel?

    public init(session: RepairSession, rectProvider: WordRectProvider = AXWordRectProvider()) {
        self.session = session
        self.rectProvider = rectProvider
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar + 1
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        host = NSHostingView(rootView: RepairFanoutView(state: state, onPick: { _ in }))
        panel.contentView = host
        host.rootView = RepairFanoutView(state: state, onPick: { [weak self] n in self?.pick(number: n) })
    }

    /// Show the fan-out for the word under `point` (screen coords) or the weakest word.
    /// Returns false when the session is inactive or nothing has alternates.
    @discardableResult
    public func show(at point: CGPoint? = nil, fieldOffset: Int) -> Bool {
        guard session.isActive(), let utterance = session.current else { hide(); return false }
        let rects = Self.wordRects(for: utterance.spans, fieldOffset: fieldOffset, provider: rectProvider)
        guard let index = RepairFanoutModel.spanIndex(under: point, wordRects: rects, spans: utterance.spans),
              let m = RepairFanoutModel(span: utterance.spans[index], index: index) else { hide(); return false }
        model = m
        state.model = m
        let screen = (NSScreen.screens.first { $0.frame.contains(point ?? NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let anchor = rects[index] ?? CGRect(origin: point ?? NSEvent.mouseLocation, size: CGSize(width: 1, height: RepairFanoutModel.rowHeight))
        panel.setFrame(m.frame(anchoredTo: anchor, in: screen), display: true)
        SpaceMembership.orderIn([panel]) // fix notch: rejoin every Space
        return true
    }

    public func hide() {
        model = nil
        state.model = nil
        panel.orderOut(nil)
    }

    public var isVisible: Bool { panel.isVisible }

    /// Voice or click pick ("number two").
    @discardableResult
    public func pick(number: Int) -> RepairResult? {
        guard let m = model, let idx = m.alternateIndex(forNumber: number) else { return nil }
        let result = session.choose(alternate: idx, of: m.spanIndex)
        hide()
        return result
    }

    static func wordRects(for spans: [TranscriptSpan], fieldOffset: Int, provider: WordRectProvider) -> [Int: CGRect] {
        var out: [Int: CGRect] = [:]
        var cursor = fieldOffset
        for (i, span) in spans.enumerated() {
            let len = span.text.utf16.count
            if !span.alternates.isEmpty, let r = provider.wordRect(utf16Range: cursor..<(cursor + len)) { out[i] = r }
            cursor += len + 1
        }
        return out
    }
}

final class RepairFanoutState: ObservableObject {
    @Published var model: RepairFanoutModel?
}

struct RepairFanoutView: View {
    @ObservedObject var state: RepairFanoutState
    var onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let m = state.model {
                ForEach(m.items) { item in
                    Button(action: { onPick(item.number) }) {
                        HStack(spacing: 8) {
                            Text("\(item.number)").font(.system(size: 11, weight: .semibold, design: .rounded))
                                .frame(width: 16, height: 16).background(Circle().fill(Color.accentColor.opacity(0.25)))
                            Text(item.text).font(.system(size: 13))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: RepairFanoutModel.rowHeight)
                        .background(item.number == m.highlighted ? Color.accentColor.opacity(0.2) : Color.clear)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Alternate \(item.number): \(item.text)")
                }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
    }
}
