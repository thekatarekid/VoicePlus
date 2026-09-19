import Engine
import Shared
import SwiftUI

// S7c — the expanded meeting capture panel (design §4 "Meeting expanded panel 560 × 360 pt preferred:
// explicit expansion; static compact cassette in the header, readable transcript below"; §8.2
// "Transcript / Notes / Ask, Pause, Stop, timer and explicit mic/system-audio track indicators").
// It is the pill expanded, so it keeps the pill's always-dark inks (`Tokens.Pill`). Everything it says
// comes from `MeetingPanelContent`, which is the same state the pill's Q0 / Q1 / Q2 rows show.

/// The panel's words that are not the pill's.
enum MeetingPanelCopy {
    static let collapse = "Collapse"
    static let waitingForWords = "Words appear here as people speak."
    static let noWordsWhilePaused = "Capture is paused. Nothing is being recorded."
    static let draftNotes = "Draft — final notes are prepared when you stop."
    static let noDraftYet = "Notes build up from the transcript as the meeting goes on."
    static let openMeetings = "Open Meetings"
}

struct MeetingPanelView: View {
    @ObservedObject var capture: MeetingCaptureController
    var askRoute: MeetingAskRoute?
    var onCollapse: () -> Void
    var onReviewPermissions: () -> Void
    var onOpenProviders: () -> Void
    var onOpenMeetings: () -> Void

    @State private var tab: MeetingPanelTab = .transcript

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let content = MeetingPanelContent(state: capture.state, now: context.date)
            VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                header(content)
                trackRow(content)
                if let notice = content.notice { noticeView(notice) }
                SegmentedControl("Meeting view", selection: $tab, identifier: "meetingPanel.tabs") { $0.title }
                    .colorScheme(.dark)
                ScrollView { tabContent.frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: .infinity)
            }
            .padding(Tokens.Spacing.l)
        }
        .frame(width: MeetingPanelController.preferredSize.width, height: MeetingPanelController.preferredSize.height)
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.pill, style: .continuous).fill(Tokens.Pill.Token.background.color))
        .foregroundStyle(Tokens.Pill.Token.ink.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meetingPanel")
    }

    // MARK: Header — static compact cassette, status, timer, controls

    private func header(_ content: MeetingPanelContent) -> some View {
        HStack(alignment: .center, spacing: Tokens.Spacing.m) {
            // Still, whatever capture is doing: the transcript below is open for reading (design §8.9).
            SpoolCameo(content.spool.key, size: .note)
            VStack(alignment: .leading, spacing: 2) {
                Text(content.status)
                    .windowFont(Tokens.Typography.pillStatus)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("meetingPanel.status")
                if !content.detail.isEmpty {
                    Text(content.detail)
                        .windowFont(Tokens.Typography.pillStatus)
                        .foregroundStyle(Tokens.Pill.Token.secondaryInk.color)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Tokens.Spacing.s)
            Text(content.timer)
                .windowFont(Tokens.Typography.pillTimer)
                .accessibilityLabel("Elapsed \(content.timer)")
                .accessibilityIdentifier("meetingPanel.timer")
            ForEach(content.buttons, id: \.self) { button in
                Button(button.title) { perform(button) }
                    .buttonStyle(.borderedProminent)
                    .tint(button.isPrimary ? Tokens.Pill.Token.primary.color : Tokens.Pill.Token.control.color)
                    .foregroundStyle(button.isPrimary ? Tokens.Pill.Token.onPrimary.color : Tokens.Pill.Token.ink.color)
                    .controlSize(.small)
                    .accessibilityIdentifier("meetingPanel.\(button.rawValue)")
            }
            if content.buttons.isEmpty, capture.state.phase == .idle {
                Button(MeetingPanelCopy.openMeetings, action: onOpenMeetings)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("meetingPanel.openMeetings")
            }
            Button(action: onCollapse) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .help(MeetingPanelCopy.collapse)
            .accessibilityLabel(MeetingPanelCopy.collapse)
            .accessibilityIdentifier("meetingPanel.collapse")
        }
    }

    private func perform(_ button: MeetingPanelButton) {
        Task {
            switch button {
            case .pause: await capture.pause()
            case .resume: await capture.resume()
            case .stop: await capture.stop()
            }
        }
    }

    // MARK: Track indicators

    private func trackRow(_ content: MeetingPanelContent) -> some View {
        HStack(spacing: Tokens.Spacing.s) {
            ForEach(content.tracks) { indicator in
                HStack(spacing: Tokens.Spacing.xs) {
                    Image(systemName: indicator.systemImage)
                    Text("\(indicator.name) · \(indicator.condition.word)")
                }
                .windowFont(Tokens.Typography.pillStatus)
                .foregroundStyle(color(for: indicator.condition))
                .padding(.horizontal, Tokens.Spacing.s)
                .padding(.vertical, 2)
                .overlay(Capsule().strokeBorder(Tokens.Pill.Token.controlBorder.color, lineWidth: 1))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(indicator.accessibilityLabel)
                .accessibilityIdentifier("meetingPanel.track.\(indicator.id)")
            }
            Spacer(minLength: 0)
        }
    }

    private func color(for condition: MeetingTrackIndicator.Condition) -> Color {
        switch condition {
        case .recording: return Tokens.Pill.Token.ready.color
        case .missing: return Tokens.Pill.Token.attention.color
        case .paused, .stopped: return Tokens.Pill.Token.secondaryInk.color
        }
    }

    // MARK: Missing-track notice (X01)

    private func noticeView(_ notice: SectionBanner) -> some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.s) {
            Image(systemName: "exclamationmark.triangle")
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.headline).fontWeight(.semibold)
                if let body = notice.body {
                    Text(body).foregroundStyle(Tokens.Pill.Token.secondaryInk.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Tokens.Spacing.s)
            if let action = notice.actionTitle {
                Button(action, action: onReviewPermissions)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("meetingPanel.notice.action")
            }
        }
        .windowFont(Tokens.Typography.pillStatus)
        .foregroundStyle(Tokens.Pill.Token.attention.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meetingPanel.notice")
    }

    // MARK: Tabs

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .transcript: transcript
        case .notes: notes
        case .ask: MeetingAskView(route: askRoute, onOpenProviders: onOpenProviders, dark: true)
        }
    }

    @ViewBuilder private var transcript: some View {
        let lines = MeetingTranscriptLine.lines(capture.state.transcript)
        if lines.isEmpty {
            Text(emptyTranscriptLine)
                .windowFont(Tokens.Typography.body)
                .foregroundStyle(Tokens.Pill.Token.secondaryInk.color)
        } else {
            ScrollViewReader { proxy in
                LazyVStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    ForEach(lines) { line in
                        MeetingTranscriptLineView(line: line, dark: true).id(line.id)
                    }
                }
                .onChange(of: lines.count) { _, _ in
                    if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyTranscriptLine: String {
        switch capture.state.phase {
        case .paused: return MeetingPanelCopy.noWordsWhilePaused
        case .idle: return MeetingPanelContent.idleStatus
        default: return MeetingPanelCopy.waitingForWords
        }
    }

    @ViewBuilder private var notes: some View {
        let draft = MeetingNotesContent(ExtractiveNotesProvider.generate(capture.state.transcript))
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            Text(draft.isEmpty ? MeetingPanelCopy.noDraftYet : MeetingPanelCopy.draftNotes)
                .windowFont(Tokens.Typography.meta)
                .foregroundStyle(Tokens.Pill.Token.secondaryInk.color)
            if !draft.isEmpty {
                MeetingNotesSections(notes: draft, completed: [], onToggle: nil, dark: true)
            }
        }
    }
}

// MARK: - Shared by the panel and the Meetings detail

/// One transcript line: "00:14 · You" eyebrow over the words; uncertain lines carry the dotted mark.
struct MeetingTranscriptLineView: View {
    var line: MeetingTranscriptLine
    var dark: Bool
    var onSeek: ((TimeInterval) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            HStack(spacing: Tokens.Spacing.s) {
                Text(line.eyebrow.uppercased())
                    .windowFont(Tokens.Typography.key)
                    .foregroundStyle(secondary)
                if let onSeek {
                    Button { onSeek(line.start) } label: { Image(systemName: "play.circle") }
                        .buttonStyle(.plain)
                        .foregroundStyle(secondary)
                        .help(MeetingsCopy.playFromHere)
                        .accessibilityLabel("\(MeetingsCopy.playFromHere), \(line.eyebrow)")
                        .accessibilityIdentifier("meetings.transcript.seek")
                }
            }
            text
                .windowFont(Tokens.Typography.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(line.isUncertain ? "\(line.eyebrow). \(line.text), \(MeetingsCopy.uncertain)" : "\(line.eyebrow). \(line.text)")
    }

    private var text: some View {
        Text(line.text)
            .underline(line.isUncertain, pattern: .dot, color: uncertainty)
    }

    private var secondary: Color { dark ? Tokens.Pill.Token.secondaryInk.color : WindowColor.secondaryInk }
    private var uncertainty: Color { dark ? Tokens.Pill.Token.uncertainty.color : WindowColor.uncertainty }
}

/// Summary · Decisions · Action items (prototype Notes tab: `h3` sections, action items as toggles).
struct MeetingNotesSections: View {
    var notes: MeetingNotesContent
    var completed: Set<String>
    /// `nil` draws the action items as plain lines (the panel's draft).
    var onToggle: ((String, Bool) -> Void)?
    var dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
            section(MeetingsCopy.summary) {
                Text(notes.summary.isEmpty ? MeetingsCopy.nothingNoted : notes.summary)
                    .foregroundStyle(notes.summary.isEmpty ? secondary : primary)
                    .textSelection(.enabled)
            }
            section(MeetingsCopy.decisions) {
                list(notes.decisions)
            }
            section(MeetingsCopy.actionItems) {
                if notes.actionItems.isEmpty {
                    Text(MeetingsCopy.nothingNoted).foregroundStyle(secondary)
                } else if let onToggle {
                    ForEach(notes.actionItems, id: \.self) { item in
                        Toggle(item, isOn: Binding(get: { completed.contains(item) }, set: { onToggle(item, $0) }))
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("meetings.notes.actionItem")
                    }
                } else {
                    list(notes.actionItems)
                }
            }
        }
        .windowFont(Tokens.Typography.body)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text(title)
                .windowFont(Tokens.Typography.section)
                .foregroundStyle(primary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    @ViewBuilder private func list(_ items: [String]) -> some View {
        if items.isEmpty {
            Text(MeetingsCopy.nothingNoted).foregroundStyle(secondary)
        } else {
            ForEach(items, id: \.self) { item in
                Text("• \(item)").foregroundStyle(primary).textSelection(.enabled)
            }
        }
    }

    private var primary: Color { dark ? Tokens.Pill.Token.ink.color : WindowColor.ink }
    private var secondary: Color { dark ? Tokens.Pill.Token.secondaryInk.color : WindowColor.secondaryInk }
}

/// Ask (prototype Ask tab): "Choose how to ask." with Open Providers, and the question field disabled
/// with "Needs a configured service" until a route exists. The route is always disclosed before use.
struct MeetingAskView: View {
    var route: MeetingAskRoute?
    var onOpenProviders: () -> Void
    var dark: Bool
    /// Answers a question; `nil` keeps the field disabled even with a route (Ask ships in a later wave).
    var ask: ((String) async throws -> String)? = nil

    @State private var question = ""
    @State private var answer: String?
    @State private var failed = false
    @State private var asking = false

    var isEnabled: Bool { route != nil && ask != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            if route == nil {
                VStack(spacing: Tokens.Spacing.s) {
                    Image(systemName: "arrow.up.right").imageScale(.large).foregroundStyle(secondary)
                    Text(MeetingsCopy.askHeadline)
                        .windowFont(Tokens.Typography.section)
                        .foregroundStyle(primary)
                    Text(MeetingsCopy.askBody)
                        .windowFont(Tokens.Typography.body)
                        .foregroundStyle(secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(MeetingsCopy.openProviders, action: onOpenProviders)
                        .buttonStyle(.borderedProminent)
                        .tint(dark ? Tokens.Pill.Token.primary.color : WindowColor.accent)
                        .accessibilityIdentifier("meetings.ask.openProviders")
                }
                .frame(maxWidth: .infinity)
            }
            HStack(spacing: Tokens.Spacing.s) {
                TextField(isEnabled ? MeetingsCopy.askPlaceholder : MeetingsCopy.askNeedsService, text: $question)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!isEnabled || asking)
                    .accessibilityIdentifier("meetings.ask.field")
                Button(MeetingsCopy.ask) { submit() }
                    .disabled(!isEnabled || asking || question.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("meetings.ask.submit")
            }
            if !isEnabled {
                Text(MeetingsCopy.askNeedsService)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(secondary)
                    .accessibilityIdentifier("meetings.ask.needsService")
            }
            Text(MeetingAskRoute.disclosure(route))
                .windowFont(Tokens.Typography.meta)
                .foregroundStyle(secondary)
                .accessibilityIdentifier("meetings.ask.route")
            if let answer {
                Text(answer).windowFont(Tokens.Typography.body).foregroundStyle(primary).textSelection(.enabled)
            } else if failed {
                Text(MeetingsCopy.askFailed).windowFont(Tokens.Typography.meta).foregroundStyle(dark ? Tokens.Pill.Token.attention.color : WindowColor.attention)
            }
        }
    }

    private func submit() {
        guard let ask, isEnabled else { return }
        let q = question
        asking = true
        failed = false
        Task { @MainActor in
            do { answer = try await ask(q) } catch { failed = true }
            asking = false
        }
    }

    private var primary: Color { dark ? Tokens.Pill.Token.ink.color : WindowColor.ink }
    private var secondary: Color { dark ? Tokens.Pill.Token.secondaryInk.color : WindowColor.secondaryInk }
}
