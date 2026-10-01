import Engine
import SwiftUI

// V5 M16 + M21 — the meeting detail's Ask tab, enabled. The route is disclosed above the field
// before anything is sent ("Route: SpeakoFlow Mini on this Mac. The transcript stays here." /
// "Route: claude-cli. This meeting's transcript is sent there when you ask."); answers cite the
// transcript's timestamps, each one a button that seeks the retained audio (M5) or, without audio,
// jumps the Transcript tab's search to that moment. While the meeting is live the retrieval index
// is refreshed every 30 s.

@MainActor
final class MeetingAskModel: ObservableObject {
    @Published var question = ""
    @Published private(set) var answer: MeetingAnswer?
    @Published private(set) var failed = false
    @Published private(set) var asking = false

    let ask: (String) async throws -> MeetingAnswer

    init(ask: @escaping (String) async throws -> MeetingAnswer) { self.ask = ask }

    var canSubmit: Bool { !asking && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func submit() async {
        guard canSubmit else { return }
        asking = true
        failed = false
        defer { asking = false }
        do { answer = try await ask(question) } catch {
            answer = nil
            failed = true
        }
    }
}

struct MeetingsAskTab: View {
    var route: MeetingAskRoute?
    var isLive: Bool
    var onOpenProviders: () -> Void
    var ask: (String) async throws -> MeetingAnswer
    var refreshLive: () async -> Void
    var onCitation: (TimeInterval) -> Void
    /// V5 M22 — the provider picker changed the route; the owner re-reads it.
    var onBackendChanged: () -> Void

    @StateObject private var model: MeetingAskModel

    init(route: MeetingAskRoute?, isLive: Bool, onOpenProviders: @escaping () -> Void,
         ask: @escaping (String) async throws -> MeetingAnswer, refreshLive: @escaping () async -> Void,
         onCitation: @escaping (TimeInterval) -> Void, onBackendChanged: @escaping () -> Void = {}) {
        self.route = route
        self.onBackendChanged = onBackendChanged
        self.isLive = isLive
        self.onOpenProviders = onOpenProviders
        self.ask = ask
        self.refreshLive = refreshLive
        self.onCitation = onCitation
        _model = StateObject(wrappedValue: MeetingAskModel(ask: ask))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            MeetingsBackendPicker(onChange: onBackendChanged)   // V5 M22
            askBody
        }
    }

    @ViewBuilder private var askBody: some View {
        if route == nil {
            // No local model and nothing pinned: the existing "Choose how to ask." state.
            MeetingAskView(route: nil, onOpenProviders: onOpenProviders, dark: false)
        } else {
            enabled
                .task(id: isLive) {
                    guard isLive else { return }
                    while !Task.isCancelled {
                        await refreshLive()
                        try? await Task.sleep(nanoseconds: UInt64(MeetingRetrieval.liveReindexInterval * 1_000_000_000))
                    }
                }
        }
    }

    private var enabled: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            Text(MeetingAskRoute.disclosure(route))
                .windowFont(Tokens.Typography.meta)
                .foregroundStyle(WindowColor.secondaryInk)
                .accessibilityIdentifier("meetings.ask.route")
            HStack(spacing: Tokens.Spacing.s) {
                TextField(MeetingsCopy.askPlaceholder, text: $model.question)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.asking)
                    .onSubmit { Task { await model.submit() } }
                    .accessibilityIdentifier("meetings.ask.field")
                Button(MeetingsCopy.ask) { Task { await model.submit() } }
                    .disabled(!model.canSubmit)
                    .accessibilityIdentifier("meetings.ask.submit")
            }
            if isLive {
                Text(MeetingsAskCopy.liveNote)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
            }
            if model.asking {
                Text(MeetingsAskCopy.asking).windowFont(Tokens.Typography.meta).foregroundStyle(WindowColor.secondaryInk)
            } else if let answer = model.answer {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    Text(answer.text)
                        .windowFont(Tokens.Typography.body)
                        .foregroundStyle(WindowColor.ink)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("meetings.ask.answer")
                    if !answer.citations.isEmpty {
                        HStack(spacing: Tokens.Spacing.s) {
                            Text(MeetingsAskCopy.sources).windowFont(Tokens.Typography.meta).foregroundStyle(WindowColor.secondaryInk)
                            ForEach(answer.citations, id: \.self) { t in
                                Button(MeetingClock.text(t)) { onCitation(t) }
                                    .buttonStyle(.link)
                                    .accessibilityLabel(MeetingsAskCopy.citationLabel(t))
                            }
                        }
                        .accessibilityIdentifier("meetings.ask.citations")
                    }
                }
            } else if model.failed {
                Text(MeetingsCopy.askFailed).windowFont(Tokens.Typography.meta).foregroundStyle(WindowColor.attention)
            }
        }
    }
}

enum MeetingsAskCopy {
    static let asking = "Asking…"
    static let sources = "From"
    static let liveNote = "Recording now — answers cover what was said up to the last 30 seconds."
    static func citationLabel(_ t: TimeInterval) -> String { "Play from \(MeetingClock.text(t))" }
    // M17 template picker on the Notes tab.
    static let template = "Template"
    static let regenerate = "Prepare notes again"
}
