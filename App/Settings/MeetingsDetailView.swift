import AVFoundation
import Engine
import Shared
import SwiftUI

// S7c — one meeting (design §8.2; prototype `meeting-detail`): the header "Product standup ·
// 18 September · 24 min · Saved on this Mac" with Export…, then Notes (Summary, Decisions, Action
// items) / Transcript (speaker labels, timestamps, search, uncertainty marks; audio seeking only when
// audio was kept) / Ask (disabled until a service is configured; the route is disclosed). A notes
// failure is a scoped banner over Notes and never hides the transcript. Static mark only (§8.9).

struct MeetingsDetailView: View {
    @ObservedObject var model: MeetingsSectionViewModel
    var record: MeetingRecord
    var hotkey: String
    var open: (WindowRoute) -> Void
    var expandPanel: () -> Void

    @StateObject private var player = MeetingAudioPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            backBar
            SectionPage(pageCopy, state: model.transcript,
                        headerAction: PageAction(MeetingsCopy.export, isPrimary: false, identifier: "meetings.detail.export") {
                            MeetingExport.save(record, markdown: model.markdown(for: record))
                        },
                        onStateAction: { open(WindowRoute(.voice)) },
                        hotkey: hotkey) {
                content
            }
        }
        .onDisappear { player.stop() }
    }

    private var pageCopy: PageCopy {
        let header = model.header
        return PageCopy(.meetingDetail, title: header?.title ?? record.title, subtitle: header?.subtitle ?? "",
                        name: record.title)
    }

    /// Back to the library; the list keeps its search and scroll.
    private var backBar: some View {
        HStack {
            Button { model.closeDetail() } label: {
                Label(MeetingsCopy.back, systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(WindowColor.accent)
            .keyboardShortcut("[", modifiers: .command)
            .accessibilityIdentifier("meetings.detail.back")
            Spacer()
            if model.live?.meetingID == record.id {
                Button("Expand", action: expandPanel)
                    .accessibilityIdentifier("meetings.detail.expand")
            }
        }
        .windowFont(Tokens.Typography.body)
        .padding(.horizontal, MainWindowLayout.outerPadding)
        .padding(.top, Tokens.Spacing.m)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
            ForEach(model.captureNotes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
            }
            SegmentedControl("Meeting view", selection: $model.detailTab, identifier: "meetings.detail.tabs") { $0.title }
                .frame(maxWidth: 360)
            switch model.detailTab {
            case .notes: notes
            case .transcript: transcript
            case .ask:
                MeetingPaper {
                    MeetingAskView(route: model.askRoute, onOpenProviders: { open(.settings(.providers)) }, dark: false)
                }
            }
        }
    }

    // MARK: Notes

    @ViewBuilder private var notes: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
            if let banner = model.notesBanner {
                ScopedBanner(banner, isRetrying: model.retryingNotes) { Task { await model.retryNotes() } }
                    .accessibilityIdentifier("meetings.detail.notesBanner")
            }
            if let notes = model.notes {
                MeetingPaper {
                    MeetingNotesSections(notes: notes, completed: model.completedActionItems,
                                         onToggle: { item, done in model.setActionItem(item, done: done) }, dark: false)
                }
            } else if model.live?.meetingID == record.id {
                Text(MeetingsCopy.preparingNotes + "…")
                    .windowFont(Tokens.Typography.body)
                    .foregroundStyle(WindowColor.secondaryInk)
            }
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            HStack(spacing: Tokens.Spacing.s) {
                TextField(MeetingsCopy.searchTranscript, text: $model.transcriptQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .accessibilityIdentifier("meetings.transcript.search")
                if !model.transcriptQuery.isEmpty {
                    Text(MeetingsCopy.matchCount(model.visibleLines.count))
                        .windowFont(Tokens.Typography.meta)
                        .foregroundStyle(WindowColor.secondaryInk)
                }
            }
            MeetingPaper {
                if model.visibleLines.isEmpty && !model.transcriptQuery.isEmpty {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                        Text(MeetingsCopy.noMatches(model.transcriptQuery))
                            .windowFont(Tokens.Typography.body)
                        Button(MeetingsCopy.clearSearch) { model.transcriptQuery = "" }
                    }
                } else {
                    LazyVStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                        ForEach(model.visibleLines) { line in
                            MeetingTranscriptLineView(line: line, dark: false, onSeek: seek)
                        }
                    }
                }
                if model.retainedAudio == nil {
                    Text(MeetingsCopy.audioOnlyWhenRetained)
                        .windowFont(Tokens.Typography.meta)
                        .foregroundStyle(WindowColor.secondaryInk)
                        .padding(.top, Tokens.Spacing.m)
                        .accessibilityIdentifier("meetings.transcript.noAudio")
                }
            }
        }
    }

    /// Seeking exists only when audio was kept.
    private var seek: ((TimeInterval) -> Void)? {
        guard let url = model.retainedAudio else { return nil }
        return { time in player.play(url, from: time) }
    }
}

/// The prototype's `.paper`: long-form reading on the surface fill inside a hairline.
struct MeetingPaper<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.group, style: .continuous)
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(Tokens.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(WindowColor.surface))
            .overlay(shape.strokeBorder(WindowColor.separator, lineWidth: 1))
    }
}

/// Plays a meeting's retained audio from a transcript timestamp.
@MainActor
final class MeetingAudioPlayer: ObservableObject {
    private var player: AVAudioPlayer?
    private var url: URL?

    func play(_ url: URL, from time: TimeInterval) {
        if self.url != url || player == nil {
            player = try? AVAudioPlayer(contentsOf: url)
            self.url = url
        }
        guard let player else { return }
        player.currentTime = min(max(0, time), player.duration)
        player.play()
    }

    func stop() {
        player?.stop()
    }
}
