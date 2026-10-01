import AppKit
import Pipeline
import Shared
import SwiftUI

// MARK: - V5 I3 · "Why did it write that?" sheet
//
// Reads `TurnTraceRecorder` (Pipeline/Cleanup/TurnTrace.swift): the last 20 dictation turns, each
// with the recognizer's text and every stage's before → after. In memory only; "Clear" forgets them.
// Opened from the menu item `WhyItWroteThatMenu` adds to the status menu (the pill's menu), and by
// `WhyItWroteThatWindow.shared.show()` from anywhere else.

public enum WhyItWroteThatCopy {
    public static let menuTitle = "Why did it write that?"
    public static let menuID = "whyItWroteThat"
    public static let windowTitle = "Why did it write that?"
    public static let footer = "Kept in memory for your last 20 dictations only. Never saved to disk."
    public static let empty = "Dictate something and it will show up here, stage by stage."

    public static func noChange(_ note: String?) -> String {
        guard let note, !note.isEmpty else { return "No change" }
        return "No change · \(reason(note))"
    }

    /// Cleanup reason codes in plain words.
    public static func reason(_ code: String) -> String {
        switch code {
        case "accepted": return "rewritten by the cleanup model"
        case "unchanged": return "the model found nothing to fix"
        case "timeout": return "the model was too slow; your words were kept"
        case "unmappable": return "the result could not be lined up with your words; kept as heard"
        case "skipped:noCue": return "nothing to clean up"
        case "skipped:off": return "AI cleanup is off"
        case "skipped:noModel": return "no cleanup model installed"
        case "skipped:verbatim": return "verbatim app rule"
        case "skipped:register", "skipped:fieldRole": return "not used in code, terminals or password fields"
        case "skipped:empty": return "nothing was said"
        default:
            if code.hasPrefix("rejected:") { return "the model's rewrite was rejected (\(code.dropFirst(9))); your words were kept" }
            if code.hasPrefix("failed:") { return "the model failed; your words were kept" }
            return code
        }
    }
}

@MainActor
public final class WhyItWroteThatModel: ObservableObject {
    public let recorder: TurnTraceRecorder
    @Published public private(set) var turns: [TurnTrace] = []
    @Published public var selection: UUID?

    public init(recorder: TurnTraceRecorder = .shared) {
        self.recorder = recorder
        reload()
    }

    public func reload() {
        turns = recorder.recent
        if selection == nil || !turns.contains(where: { $0.id == selection }) { selection = turns.first?.id }
    }

    public var selected: TurnTrace? { turns.first { $0.id == selection } ?? turns.first }

    public func clear() {
        recorder.clear()
        reload()
    }

    public static func label(for turn: TurnTrace) -> String {
        let time = turn.date.formatted(date: .omitted, time: .shortened)
        let app = turn.appBundleID.map { $0.split(separator: ".").last.map(String.init) ?? $0 } ?? "Unknown app"
        let preview = turn.output.count > 40 ? String(turn.output.prefix(40)) + "…" : turn.output
        return "\(time) · \(app) · \(preview)"
    }
}

struct WhyItWroteThatView: View {
    @ObservedObject var model: WhyItWroteThatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.turns.isEmpty {
                Text(WhyItWroteThatCopy.empty).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Picker("Dictation", selection: $model.selection) {
                    ForEach(model.turns) { turn in
                        Text(WhyItWroteThatModel.label(for: turn)).tag(Optional(turn.id))
                    }
                }
                if let turn = model.selected { TurnDetail(turn: turn) }
            }
            Divider()
            HStack {
                Text(WhyItWroteThatCopy.footer).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { model.reload() }
                Button("Clear") { model.clear() }.disabled(model.turns.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 380)
    }
}

private struct TurnDetail: View {
    let turn: TurnTrace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Row(title: "Heard", detail: "field: \(turn.fieldRole.rawValue)") { Text(turn.input).textSelection(.enabled) }
                ForEach(turn.explainedSteps) { step in
                    Row(title: step.title, detail: step.changed ? step.note.map(WhyItWroteThatCopy.reason) : nil) {
                        if step.changed { DiffText(pieces: StageDiffText.pieces(before: step.before, after: step.after)) }
                        else { Text(WhyItWroteThatCopy.noChange(step.note)).foregroundStyle(.secondary) }
                    }
                }
                Row(title: "Written", detail: nil) { Text(turn.output).bold().textSelection(.enabled) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct Row<Content: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            content
        }
        .accessibilityElement(children: .combine)
    }
}

/// Removed words struck through in red, added words in green, kept words plain.
private struct DiffText: View {
    let pieces: [StageDiffText.Piece]

    var body: some View {
        pieces.enumerated().reduce(Text("")) { acc, item in
            let (i, p) = item
            let sep = i == 0 ? "" : " "
            switch p.kind {
            case .kept: return acc + Text(sep + p.text)
            case .removed: return acc + Text(sep) + Text(p.text).strikethrough().foregroundColor(.red)
            case .added: return acc + Text(sep) + Text(p.text).foregroundColor(.green).bold()
            }
        }
        .textSelection(.enabled)
        .accessibilityLabel(pieces.map { p in
            switch p.kind {
            case .kept: return p.text
            case .removed: return "removed: \(p.text)"
            case .added: return "added: \(p.text)"
            }
        }.joined(separator: ", "))
    }
}

/// The sheet's window (one, reused).
@MainActor
public final class WhyItWroteThatWindow {
    public static let shared = WhyItWroteThatWindow()
    private var window: NSWindow?
    private var model: WhyItWroteThatModel?

    public func show(recorder: TurnTraceRecorder = .shared) {
        let model = self.model ?? WhyItWroteThatModel(recorder: recorder)
        self.model = model
        model.reload()
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: WhyItWroteThatView(model: model)))
        w.title = WhyItWroteThatCopy.windowTitle
        w.styleMask = [.titled, .closable, .resizable]
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 600, height: 460))
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

/// The menu row. Only present once at least one turn was traced.
public enum WhyItWroteThatMenu {
    @MainActor
    public static func item(recorder: TurnTraceRecorder = .shared) -> NSMenuItem? {
        guard recorder.latest != nil else { return nil }
        let item = NSMenuItem(title: WhyItWroteThatCopy.menuTitle, action: #selector(Target.open(_:)), keyEquivalent: "")
        item.target = Target.shared
        item.identifier = NSUserInterfaceItemIdentifier(WhyItWroteThatCopy.menuID)
        return item
    }

    @MainActor
    final class Target: NSObject {
        static let shared = Target()
        @objc func open(_ sender: Any?) { WhyItWroteThatWindow.shared.show() }
    }
}

/// App wiring: every pipeline stage traced into the shared recorder; the cleanup stage's reason
/// code attached as a note.
public enum TurnTraceWiring {
    public static func traced(_ stages: [any PipelineStage], recorder: TurnTraceRecorder = .shared) -> [any PipelineStage] {
        TracedStage.wrapping(stages.map { stage in
            guard var cleanup = stage as? CleanupStage else { return stage }
            let previous = cleanup.observer
            let id = cleanup.id
            cleanup.observer = { outcome in
                previous?(outcome)
                recorder.note(stage: id, code: outcome.code)
            }
            return cleanup
        }, recorder: recorder)
    }
}
