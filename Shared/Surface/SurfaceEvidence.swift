import Foundation

/// N9 — everything the surface resolver may look at, as plain values (R3 §E1). `App` fills it
/// from one accessibility snapshot (N7) plus the shell probe (F26) and the learned memory;
/// tests and the replay tool fill it by hand. Screen text here is data, never instructions.
public struct SurfaceEvidence: Sendable, Equatable {
    public var bundleID: String?
    /// macOS secure input is on (`IsSecureEventInputEnabled`). A veto.
    public var secureInputActive: Bool
    /// Focused element: `AXRole` / `AXSubrole`.
    public var role: String?
    public var subrole: String?
    /// The element accepts text (`AXValue` settable, or an editable ancestor). `nil` = unknown.
    public var isEditable: Bool?
    /// Single- vs multi-line, when the tree says. `nil` = unknown.
    public var isMultiline: Bool?
    /// `AXPlaceholderValue` ("Message ChatGPT", "Search mail").
    public var placeholder: String?
    /// The field's label: `AXTitle`, `AXDescription`, the `<label>` via `AXTitleUIElement`.
    public var label: String?
    /// Any other descriptive strings: `AXIdentifier`, `AXRoleDescription`, `AXDOMClassList`,
    /// aria labels. Order is irrelevant.
    public var hints: [String]
    /// The focused element has an `AXWebArea` ancestor.
    public var isInWebArea: Bool
    /// `AXURL` of that web area.
    public var url: String?
    /// The focused app owns a shell on a pty (the focused tab's shell, when known).
    public var shell: ShellContext?
    public var windowTitle: String?
    public var runtime: SurfaceRuntime?
    /// The user's per-app override (Settings). Medium-high evidence, not a veto: a find box in
    /// an app overridden to "terminal" is still a find box.
    public var appOverride: SurfaceKind?
    /// What this app (or `bundle|host`) resolved to on earlier turns, most recent last.
    public var previousKinds: [SurfaceKind]

    public init(bundleID: String? = nil, secureInputActive: Bool = false, role: String? = nil,
                subrole: String? = nil, isEditable: Bool? = nil, isMultiline: Bool? = nil,
                placeholder: String? = nil, label: String? = nil, hints: [String] = [],
                isInWebArea: Bool = false, url: String? = nil, shell: ShellContext? = nil,
                windowTitle: String? = nil, runtime: SurfaceRuntime? = nil,
                appOverride: SurfaceKind? = nil, previousKinds: [SurfaceKind] = []) {
        self.bundleID = bundleID; self.secureInputActive = secureInputActive
        self.role = role; self.subrole = subrole; self.isEditable = isEditable; self.isMultiline = isMultiline
        self.placeholder = placeholder; self.label = label; self.hints = hints
        self.isInWebArea = isInWebArea; self.url = url; self.shell = shell
        self.windowTitle = windowTitle; self.runtime = runtime
        self.appOverride = appOverride; self.previousKinds = previousKinds
    }

    /// Nothing at all came back from the accessibility tree.
    public var treeIsEmpty: Bool {
        (role ?? "").isEmpty && (subrole ?? "").isEmpty && (placeholder ?? "").isEmpty
            && (label ?? "").isEmpty && hints.isEmpty && !isInWebArea
    }

    /// Placeholder, label and hints together (the field's own words).
    public var fieldTexts: [String] { [placeholder, label].compactMap { $0 }.filter { !$0.isEmpty } + hints }
}

/// N9 — the resolver's answer. `signals` say which evidence made it, for `turn_records` and
/// diagnostics; they are labels and weights, never field contents beyond the matched phrase.
public struct SurfaceResolution: Sendable, Equatable {
    public var kind: SurfaceKind
    /// 0…1. Below `SurfaceResolver.threshold` the kind is `.prose` and `isFallback` is true.
    public var confidence: Double
    /// Text lands in web content (an `AXWebArea`, a web runtime, or an unreadable tree):
    /// keystrokes not AX writes, ⇧↩ not ↩.
    public var isWebArea: Bool
    public var signals: [String]
    /// The evidence did not reach the threshold; this is the safe prose fallback.
    public var isFallback: Bool
    /// The winning kind before the threshold was applied (for diagnostics).
    public var candidate: SurfaceKind

    public init(kind: SurfaceKind, confidence: Double, isWebArea: Bool, signals: [String],
                isFallback: Bool = false, candidate: SurfaceKind? = nil) {
        self.kind = kind; self.confidence = confidence; self.isWebArea = isWebArea
        self.signals = signals; self.isFallback = isFallback; self.candidate = candidate ?? kind
    }

    /// How a line break is typed here (R3 §E7). Never a bare Return in web content.
    public var newline: SurfaceNewline {
        switch kind {
        case .secure, .canvas, .urlBar, .searchField, .formField: return .none
        case .terminal: return .bracketedPaste
        case .spreadsheetCell: return .optionReturn
        default: return isWebArea || kind == .chatComposer ? .shiftReturn : .newline
        }
    }

    /// Never type: secure fields and canvases with no text edit active.
    public var refusesTyping: Bool { kind == .secure || kind == .canvas }

    /// Compact one-line form for `turn_records` / diagnostics:
    /// `chatComposer 0.72 web [label:message+2.5, seed:chat+1.5]`.
    public var recordValue: String {
        let conf = String(format: "%.2f", confidence)
        return "\(kind.id) \(conf)\(isWebArea ? " web" : "")\(isFallback ? " fallback(\(candidate.id))" : "") [\(signals.joined(separator: ", "))]"
    }
}
