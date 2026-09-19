import AppKit
import Engine
import SwiftUI

/// P5.3 / S7e — prompted speaker enrollment: three read phrases → embedding centroid →
/// `SpeakerProfile` handed back to the composition root (`LatchController` installs + persists).
/// The recorder closure is injected: the app records ~3 s through the engine's audio tap; tests
/// feed synthetic samples.
///
/// One view model, one view, two hosts: Voice › Your voice runs it inline, and onboarding's Voice
/// step (S8, owner decision) runs the same view with the same copy. Each take has two phases the
/// view shows: *capturing* (the microphone is open — Spool moves) and *analyzing* (the microphone is
/// closed and the phrase is being embedded — Spool parks; design §8.9).
@MainActor
public final class SpeakerEnrollmentViewModel: ObservableObject {
    /// Where one take is.
    public enum CapturePhase: Equatable, Sendable {
        case idle
        /// The recorder has the microphone open.
        case capturing
        /// The microphone is closed; the phrase is being embedded.
        case analyzing

        var activity: SpoolSurfacePolicy.Activity {
            switch self {
            case .idle: return .idle
            case .capturing: return .capturing
            case .analyzing: return .analyzing
            }
        }
    }

    @Published public private(set) var enrollment = SpeakerEnrollment()
    @Published public private(set) var status = SpeakerEnrollmentCopy.instruction
    /// True for the whole take, capture and analysis both: a second take cannot start meanwhile.
    @Published public private(set) var isRecording = false
    @Published public private(set) var capture: CapturePhase = .idle
    /// When `capture` last changed (Spool's state clock).
    @Published public private(set) var captureChangedAt = Date()
    public let embedder: any SpeakerEmbedder
    private let record: () async -> [Float]
    public var onComplete: ((SpeakerProfile) -> Void)?

    public init(embedder: any SpeakerEmbedder, record: @escaping () async -> [Float]) {
        self.embedder = embedder
        self.record = record
    }

    public var prompt: String? { enrollment.currentPrompt }
    public var progress: Double {
        Double(enrollment.embeddings.count) / Double(SpeakerEnrollment.requiredUtterances)
    }
    public var isDone: Bool { enrollment.step == .done }

    /// "Phrase 2 of 3" — a true denominator, so the progress is determinate (design §9).
    public var stepLabel: String {
        let total = SpeakerEnrollment.requiredUtterances
        return isDone ? SpeakerEnrollmentCopy.saved : "Phrase \(min(enrollment.embeddings.count + 1, total)) of \(total)"
    }

    public func recordUtterance() {
        guard !isRecording, !isDone else { return }
        isRecording = true
        setCapture(.capturing)
        status = SpeakerEnrollmentCopy.listening
        Task { @MainActor in
            let samples = await record()
            setCapture(.analyzing)
            status = SpeakerEnrollmentCopy.analyzing
            defer {
                setCapture(.idle)
                isRecording = false
            }
            guard !samples.isEmpty else {
                status = SpeakerEnrollmentCopy.noAudio
                return
            }
            let embedder = self.embedder
            let embedded = await Task.detached(priority: .userInitiated) { try? embedder.embed(samples) }.value
            guard let embedding = embedded else {
                status = SpeakerEnrollmentCopy.tooShort
                return
            }
            switch enrollment.record(embedding) {
            case .accepted(let n):
                status = SpeakerEnrollmentCopy.accepted(n)
            case .inconsistent:
                status = SpeakerEnrollmentCopy.inconsistent
            case .complete:
                status = SpeakerEnrollmentCopy.complete
                if let profile = enrollment.profile { onComplete?(profile) }
            }
        }
    }

    public func reset() {
        enrollment.reset()
        status = SpeakerEnrollmentCopy.instruction
    }

    private func setCapture(_ next: CapturePhase) {
        capture = next
        captureChangedAt = Date()
    }
}

/// The enrollment view's words — the Voice section's, and onboarding's Voice step's (owner decision).
public enum SpeakerEnrollmentCopy {
    public static let title = "Teach VoicePlus your voice"
    public static let instruction = "Read each phrase aloud in your normal voice."
    public static let listening = "Listening… read the phrase, then wait."
    public static let analyzing = "Learning that phrase. The microphone is closed."
    public static func accepted(_ n: Int) -> String { "Got it — \(n) of \(SpeakerEnrollment.requiredUtterances)." }
    public static let inconsistent = "That didn't sound like the earlier phrases. Read it again in your normal voice."
    public static let tooShort = "That was too short. Read the whole phrase, then wait."
    public static let noAudio = "No audio reached VoicePlus. Check the microphone, then record again."
    public static let complete = "Your voice is set up. Hands-free Latch will only answer to you."
    public static let saved = "Saved"
    public static let optional = "Optional. Hold-to-talk works without it."
    public static let record = "Record"
    public static let listeningButton = "Listening…"
    public static let startOver = "Start over"
    public static let done = "Done"
}

/// The enrollment itself, drawn to be embedded: in Voice › Your voice (inside the design's group)
/// and in onboarding's Voice step. It never opens a window.
public struct SpeakerEnrollmentView: View {
    @ObservedObject var model: SpeakerEnrollmentViewModel
    /// The host's "Done": Voice puts its group back, onboarding moves on. Nil hides the button.
    private let onDone: (() -> Void)?

    public init(model: SpeakerEnrollmentViewModel, onDone: (() -> Void)? = nil) {
        self.model = model
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            HStack(alignment: .center, spacing: Tokens.Spacing.l) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    Text(SpeakerEnrollmentCopy.title)
                        .windowFont(Tokens.Typography.section)
                        .accessibilityAddTraits(.isHeader)
                    Text(model.stepLabel)
                        .windowFont(Tokens.Typography.meta)
                        .foregroundStyle(WindowColor.secondaryInk)
                }
                Spacer(minLength: Tokens.Spacing.l)
                VoiceSpoolStrip(surface: .voiceEnrollment, activity: model.capture.activity,
                                since: model.captureChangedAt, level: 0)
            }
            ProgressView(value: model.progress)
                .accessibilityLabel(model.stepLabel)
            if let prompt = model.prompt {
                Text("“\(prompt)”")
                    .windowFont(Tokens.Typography.body)
                    .italic()
                    .foregroundStyle(WindowColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Tokens.Spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Tokens.Radius.control).fill(WindowColor.surface))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("enrollment.prompt")
            }
            Text(model.status)
                .windowFont(Tokens.Typography.meta)
                .foregroundStyle(WindowColor.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("enrollment.status")
            HStack(spacing: Tokens.Spacing.s) {
                Button(SpeakerEnrollmentCopy.startOver) { model.reset() }
                    .disabled(model.isRecording)
                Spacer()
                if model.isDone {
                    if let onDone {
                        Button(SpeakerEnrollmentCopy.done) { onDone() }
                            .buttonStyle(.borderedProminent)
                            .tint(WindowColor.accent)
                            .accessibilityIdentifier("enrollment.done")
                    }
                } else {
                    Button(model.isRecording ? SpeakerEnrollmentCopy.listeningButton : SpeakerEnrollmentCopy.record) {
                        model.recordUtterance()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(WindowColor.accent)
                    .disabled(model.isRecording)
                    .accessibilityIdentifier("enrollment.record")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// R7.2 — there is no enrollment window any more (`DESIGN.md` §5.1, §12.5). This is the shim the
/// composition root still calls: it opens the one window at **Voice** and hands the enrollment view
/// model to that pane, which runs it inline. Nothing here creates a window.
@MainActor
public enum SpeakerEnrollmentWindowController {
    public static func show(model: SpeakerEnrollmentViewModel) {
        MainWindowController.showEnrollment(model: model)
    }

    /// Ends the inline enrollment. It deliberately does *not* close the one window — the window is
    /// not enrollment's to close.
    public static func close() {
        MainWindowController.cancelEnrollment()
    }
}
