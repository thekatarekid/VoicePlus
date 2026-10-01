import AppKit
import ApplicationServices
import Shared
import SwiftUI

// S5 — the destination overlay, live: AX reads on the field the text landed in, AX notifications and
// workspace / display events that trigger revalidation, and the transparent, non-activating panels
// that draw the underlines. Everything that decides anything is `DestinationMarkSession` (pure); this
// file only feeds it and draws what it returns. Needs the Accessibility permission; without it there
// is no geometry and the ladder says D09.

/// AX reads on one element — the focused field of `pid` when the text landed — never "whatever is
/// focused now", so a mark can never be drawn over another field's words.
public final class AXElementMarkGeometry: MarkGeometrySource {
    let element: AXUIElement
    public let pid: pid_t

    public init(element: AXUIElement, pid: pid_t) {
        self.element = element
        self.pid = pid
    }

    /// The focused element of app `pid`, now (right after the insert it is the field the text landed in).
    public static func focused(in pid: pid_t) -> AXElementMarkGeometry? {
        guard AXIsProcessTrusted() else { return nil }
        var focused: CFTypeRef?
        // K18 — own pid → refuse; an element of ours is admitted only on the main thread.
        guard let app = AXGuard.application(pid: pid) else { return nil }
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let value = focused, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElementMarkGeometry(element: value as! AXUIElement, pid: pid)
    }

    public func currentValue() -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    public var selectedRange: Range<Int>? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range), range.location >= 0 else { return nil }
        return range.location..<(range.location + range.length)
    }

    public func rect(for range: Range<Int>) -> CGRect? {
        var cfRange = CFRange(location: range.lowerBound, length: range.count)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &bounds) == .success,
              let b = bounds, CFGetTypeID(b) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(b as! AXValue, .cgRect, &rect) else { return nil }
        return Self.appKit(rect)
    }

    public func visibleFrame() -> CGRect? {
        // A text view inside a scroll view: the scroll area is what is visible.
        var parent: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
           let p = parent, CFGetTypeID(p) == AXUIElementGetTypeID(),
           Self.role(of: p as! AXUIElement) == (kAXScrollAreaRole as String), let frame = Self.frame(of: p as! AXUIElement) {
            return frame
        }
        return Self.frame(of: element)
    }

    public var isFrontmost: Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }

    public var isAlive: Bool {
        var role: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) != .invalidUIElement
    }

    static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let p = position, let s = size, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &extent) else { return nil }
        return appKit(CGRect(origin: origin, size: extent))
    }

    /// AX rects are top-left-origin global coordinates; AppKit's are bottom-left of the primary screen.
    static func appKit(_ rect: CGRect) -> CGRect {
        RepairFanoutModel.appKitRect(fromAX: rect, primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0)
    }
}

/// Draws a session's underlines: one small transparent panel per fragment, over the underline strip
/// only (the word itself stays clickable in the app), non-activating, on every Space.
public final class DestinationMarksOverlay {
    private var panels: [NSPanel] = []
    private var suggestionPanels: [NSPanel] = []
    public var onSuggestion: ((Int, String) -> Void)?
    /// A mark was clicked: its id and the word's line box (AppKit screen coordinates).
    public var onClick: ((Int, CGRect) -> Void)?

    public init() {}

    deinit { Self.strips[ObjectIdentifier(self)] = nil }

    /// Every underline strip any overlay has on screen now (AppKit screen coordinates, main thread):
    /// S4's destination tape cue never draws over one.
    public static var visibleStrips: [CGRect] { strips.values.flatMap { $0 } }
    private static var strips: [ObjectIdentifier: [CGRect]] = [:]

    public var isVisible: Bool { panels.contains { $0.isVisible } }

    public func show(_ fragments: [DestinationMarkFragment], labels: [Int: String]) {
        while panels.count < fragments.count { panels.append(Self.makePanel()) }
        for (i, fragment) in fragments.enumerated() {
            let panel = panels[i]
            let hit = MarkStyle.hitHeight
            let frame = CGRect(x: fragment.underline.minX, y: fragment.underline.midY - hit / 2,
                               width: max(fragment.underline.width, 4), height: hit)
            panel.contentView = NSHostingView(rootView: DestinationMarkView(
                width: frame.width, label: labels[fragment.markID] ?? "",
                open: { [weak self] in self?.onClick?(fragment.markID, fragment.box) }))
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
        }
        for panel in panels.dropFirst(fragments.count) { panel.orderOut(nil) }
        Self.strips[ObjectIdentifier(self)] = panels.prefix(fragments.count).map(\.frame)
    }

    /// Brackets are decorations only, in proven blank space after the field's last word.
    /// Mid-line words keep suggestions in VoicePlus: an overlay cannot reflow someone else's text.
    public func showSuggestions(_ suggestions: [(markID: Int, text: String, frame: CGRect)]) {
        while suggestionPanels.count < suggestions.count { suggestionPanels.append(Self.makePanel()) }
        for (index, suggestion) in suggestions.enumerated() {
            let panel = suggestionPanels[index]
            panel.contentView = NSHostingView(rootView:
                Button("[or did you mean \(suggestion.text)]") { [weak self] in
                    self?.onSuggestion?(suggestion.markID, suggestion.text)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: Tokens.Colors.uncertainty))
                .accessibilityLabel("Use \(suggestion.text)"))
            panel.setFrame(suggestion.frame, display: true)
            panel.orderFrontRegardless()
        }
        for panel in suggestionPanels.dropFirst(suggestions.count) { panel.orderOut(nil) }
    }

    public func hide() {
        panels.forEach { $0.orderOut(nil) }
        suggestionPanels.forEach { $0.orderOut(nil) }
        Self.strips[ObjectIdentifier(self)] = nil
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        return panel
    }
}

/// One underline: 2 px dotted, drawn centred in its click strip.
struct DestinationMarkView: View {
    let width: CGFloat
    let label: String
    let open: () -> Void

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(path, with: .color(Color(nsColor: Tokens.Colors.uncertainty)),
                           style: StrokeStyle(lineWidth: MarkStyle.thickness, dash: MarkStyle.dash))
        }
        .frame(width: width, height: MarkStyle.hitHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityElement()
        .accessibilityLabel("\(label), \(MarkCopy.uncertainWord)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
    }
}

/// Keeps one session's overlay true: revalidates on AX notifications from the destination app, on
/// app activation / deactivation, on display changes and on a short tick while anything is on screen
/// (scrolling posts no notification), and records the per-bundle capability verdict.
public final class DestinationMarksTracker {
    public let session: DestinationMarkSession
    public let geometry: MarkGeometrySource
    public let overlay: DestinationMarksOverlay
    public var recorder: WordMarkCapabilityRecording?
    /// The session cleared (corrected, kept, changed, closed, no geometry…).
    public var onCleared: ((MarkClearReason) -> Void)?
    public var tick: TimeInterval = 0.25

    private var timer: Timer?
    private var observer: AXObserver?
    private var tokens: [NSObjectProtocol] = []
    private var recorded: Bool?

    public init(session: DestinationMarkSession, geometry: MarkGeometrySource, overlay: DestinationMarksOverlay,
                recorder: WordMarkCapabilityRecording?) {
        self.session = session
        self.geometry = geometry
        self.overlay = overlay
        self.recorder = recorder
    }

    deinit { stop() }

    public func start() {
        observeWorkspace()
        observeAX()
        let timer = Timer(timeInterval: tick, repeats: true) { [weak self] _ in self?.revalidate() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        revalidate()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        tokens.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        tokens.removeAll()
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        overlay.hide()
    }

    /// Re-reads the field and redraws; clears everything once the session is over.
    @discardableResult
    public func revalidate() -> DestinationMarkSession.Phase {
        let phase = session.revalidate(geometry)
        if let verdict = WordMarkCapabilityPolicy.verdict(for: phase, tier: session.tier), verdict != recorded {
            recorded = verdict
            recorder?.record(session.bundleID, supported: verdict)
        }
        switch phase {
        case .shown(let fragments):
            overlay.show(fragments, labels: Dictionary(uniqueKeysWithValues: session.marks.map { ($0.id, $0.text) }))
            var suggestions: [(markID: Int, text: String, frame: CGRect)] = []
            if let value = geometry.currentValue(), let visible = geometry.visibleFrame() {
                for mark in session.marks {
                    let range = session.fieldRange(of: mark)
                    guard let alternative = mark.alternatives.first,
                          let suffix = MarkWords.slice(value, range.upperBound..<value.utf16.count),
                          suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let fragment = fragments.first(where: { $0.markID == mark.id }),
                          fragments.filter({ $0.markID == mark.id }).count == 1 else { continue }
                    let label = "[or did you mean \(alternative)]" as NSString
                    let width = ceil(label.size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width) + 8
                    let frame = CGRect(x: fragment.box.maxX + 5, y: fragment.box.midY - 9, width: width, height: 18)
                    guard visible.contains(frame) else { continue }
                    suggestions.append((mark.id, alternative, frame))
                }
            }
            overlay.showSuggestions(suggestions)
        case .hidden:
            overlay.hide()
        case .cleared(let reason):
            stop()
            onCleared?(reason)
        }
        return phase
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.revalidate() })
        }
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                             object: nil, queue: .main) { [weak self] _ in self?.revalidate() })
    }

    private func observeAX() {
        guard let geometry = geometry as? AXElementMarkGeometry else { return }
        var created: AXObserver?
        // The source runs on the main run loop and is removed in `stop()` (called from `deinit`), so
        // the callback never outlives the tracker it points at.
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<DestinationMarksTracker>.fromOpaque(refcon).takeUnretainedValue().revalidate()
        }
        guard AXObserverCreate(geometry.pid, callback, &created) == .success, let observer = created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXValueChangedNotification, kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification] {
            AXObserverAddNotification(observer, geometry.element, name as CFString, refcon)
        }
        if let app = AXGuard.application(pid: geometry.pid) {   // K18
        for name in [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXFocusedWindowChangedNotification,
                     kAXWindowMiniaturizedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, refcon)
        }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = observer
    }
}
