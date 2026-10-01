import Engine
import SwiftUI

// V5 M19 — "Ask across meetings" in the Meetings library header. The same retrieval as a meeting's
// Ask tab (M16/M21) over every meeting in the library, the meeting being recorded included; the
// question goes to the `meeting.ask` route, which is disclosed before anything is sent. Each answer
// cites a meeting and a moment ("Standup · 12:04"); clicking one opens that meeting's transcript.

@MainActor
final class MeetingsAskAcrossModel: ObservableObject {
    @Published var question = ""
    @Published var expanded = false
    @Published private(set) var answer: MeetingLibraryAnswer?
    @Published private(set) var failed = false
    @Published private(set) var asking = false

    let ask: (String) async throws -> MeetingLibraryAnswer

    init(ask: @escaping (String) async throws -> MeetingLibraryAnswer) { self.ask = ask }

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

extension MeetingsSectionViewModel {
    /// V5 M19 — asks over the library as listed (what is on disk plus the meeting being captured).
    func askAcross(_ question: String,
                   using ask: (String, [MeetingRecord], String?) async throws -> MeetingLibraryAnswer = { q, records, live in
                       try await MeetingIntelligence.shared.askAcross(q, over: records, liveID: live)
                   }) async throws -> MeetingLibraryAnswer {
        try await ask(question, libraryRecords, live?.meetingID)
    }

    /// Opens the cited meeting on its transcript. False when the meeting is no longer listed.
    @discardableResult
    func open(_ citation: MeetingCitation) -> Bool {
        guard let record = libraryRecords.first(where: { $0.id == citation.meetingID }) else { return false }
        select(record)
        detailTab = .transcript
        return true
    }
}

enum MeetingsAskAcrossCopy {
    static let title = "Ask across meetings"
    static let placeholder = "Ask about all your meetings"
    static let hide = "Hide"
    static func disclosure(_ route: MeetingAskRoute?) -> String {
        guard let route else { return MeetingsCopy.askRouteNone }
        return route.isLocal ? "Route: \(route.name), on this Mac. Your meetings stay here."
                             : "Route: \(route.name). Excerpts of your meetings are sent there when you ask."
    }
    static func searched(_ n: Int) -> String { n == 1 ? "Searched 1 meeting" : "Searched \(n) meetings" }
    static func citation(_ c: MeetingCitation) -> String { "\(c.title) · \(MeetingClock.text(c.time))" }
    static func citationLabel(_ c: MeetingCitation) -> String { "Open \(c.title) at \(MeetingClock.text(c.time))" }
}

struct MeetingsAskAcrossPanel: View {
    var route: MeetingAskRoute?
    var onOpenProviders: () -> Void
    var onCitation: (MeetingCitation) -> Void
    var onBackendChanged: () -> Void
    @StateObject private var model: MeetingsAskAcrossModel

    init(route: MeetingAskRoute?, onOpenProviders: @escaping () -> Void,
         ask: @escaping (String) async throws -> MeetingLibraryAnswer, onCitation: @escaping (MeetingCitation) -> Void,
         onBackendChanged: @escaping () -> Void = {}) {
        self.route = route
        self.onBackendChanged = onBackendChanged
        self.onOpenProviders = onOpenProviders
        self.onCitation = onCitation
        _model = StateObject(wrappedValue: MeetingsAskAcrossModel(ask: ask))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack {
                Button { model.expanded.toggle() } label: {
                    Label(model.expanded ? MeetingsAskAcrossCopy.hide : MeetingsAskAcrossCopy.title,
                          systemImage: model.expanded ? "chevron.up" : "sparkle.magnifyingglass")
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("meetings.askAcross.toggle")
                Spacer()
            }
            if model.expanded { content }
        }
    }

    @ViewBuilder private var content: some View {
        MeetingsBackendPicker(onChange: onBackendChanged)   // V5 M22
        if route == nil {
            MeetingAskView(route: nil, onOpenProviders: onOpenProviders, dark: false)
        } else {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                Text(MeetingsAskAcrossCopy.disclosure(route))
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
                    .accessibilityIdentifier("meetings.askAcross.route")
                HStack(spacing: Tokens.Spacing.s) {
                    TextField(MeetingsAskAcrossCopy.placeholder, text: $model.question)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.asking)
                        .onSubmit { Task { await model.submit() } }
                        .accessibilityIdentifier("meetings.askAcross.field")
                    Button(MeetingsCopy.ask) { Task { await model.submit() } }
                        .disabled(!model.canSubmit)
                        .accessibilityIdentifier("meetings.askAcross.submit")
                }
                if model.asking {
                    Text(MeetingsAskCopy.asking).windowFont(Tokens.Typography.meta).foregroundStyle(WindowColor.secondaryInk)
                } else if let answer = model.answer {
                    answerView(answer)
                } else if model.failed {
                    Text(MeetingsCopy.askFailed).windowFont(Tokens.Typography.meta).foregroundStyle(WindowColor.attention)
                }
            }
            .padding(Tokens.Spacing.m)
            .background(RoundedRectangle(cornerRadius: 8).fill(WindowColor.secondaryInk.opacity(0.06)))
        }
    }

    private func answerView(_ answer: MeetingLibraryAnswer) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text(answer.text)
                .windowFont(Tokens.Typography.body)
                .foregroundStyle(WindowColor.ink)
                .textSelection(.enabled)
                .accessibilityIdentifier("meetings.askAcross.answer")
            if !answer.citations.isEmpty {
                HStack(spacing: Tokens.Spacing.s) {
                    Text(MeetingsAskCopy.sources).windowFont(Tokens.Typography.meta).foregroundStyle(WindowColor.secondaryInk)
                    ForEach(answer.citations, id: \.self) { c in
                        Button(MeetingsAskAcrossCopy.citation(c)) { onCitation(c) }
                            .buttonStyle(.link)
                            .accessibilityLabel(MeetingsAskAcrossCopy.citationLabel(c))
                    }
                }
                .accessibilityIdentifier("meetings.askAcross.citations")
            }
            Text(MeetingsAskAcrossCopy.searched(answer.meetingsSearched))
                .windowFont(Tokens.Typography.meta)
                .foregroundStyle(WindowColor.secondaryInk)
        }
    }
}
