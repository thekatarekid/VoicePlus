import AppKit
import Engine
import SwiftUI

/// P5.3 — onboarding-2: speaker enrollment. Three prompted utterances → embedding centroid →
/// `SpeakerProfile` handed back to the composition root (HandsFreeController installs + persists).
/// The recorder closure is injected: the app records ~3 s through the engine's audio tap; tests
/// feed synthetic samples.
@MainActor
public final class SpeakerEnrollmentViewModel: ObservableObject {
    @Published public private(set) var enrollment = SpeakerEnrollment()
    @Published public private(set) var status = "Read each phrase aloud in your normal voice."
    @Published public private(set) var isRecording = false
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

    public func recordUtterance() {
        guard !isRecording, !isDone else { return }
        isRecording = true
        status = "Listening…"
        Task { @MainActor in
            let samples = await record()
            defer { isRecording = false }
            do {
                let embedding = try embedder.embed(samples)
                switch enrollment.record(embedding) {
                case .accepted(let n):
                    status = "Got it (\(n)/\(SpeakerEnrollment.requiredUtterances))."
                case .inconsistent(let similarity):
                    status = "That didn't sound like the earlier takes (similarity \(String(format: "%.2f", similarity))). Try again."
                case .complete:
                    status = "Voice profile saved. Hands-free will only answer to you."
                    if let profile = enrollment.profile { onComplete?(profile) }
                }
            } catch {
                status = "Too short — hold the phrase a little longer."
            }
        }
    }

    public func reset() {
        enrollment.reset()
        status = "Read each phrase aloud in your normal voice."
    }
}

public struct SpeakerEnrollmentView: View {
    @ObservedObject var model: SpeakerEnrollmentViewModel
    /// R7.2 — the view runs inside Voice › Enrollment now, so "Done" hands control back to that pane
    /// instead of closing a window of its own.
    private let onDone: (() -> Void)?

    public init(model: SpeakerEnrollmentViewModel, onDone: (() -> Void)? = nil) {
        self.model = model
        self.onDone = onDone
    }

    public var body: some View {
        VStack(spacing: 14) {
            Text("Teach VoicePlus your voice").font(.title3.bold())
            ProgressView(value: model.progress)
            if let prompt = model.prompt {
                Text("“\(prompt)”").font(.body.italic()).multilineTextAlignment(.center)
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Start over") { model.reset() }.disabled(model.isRecording)
                Spacer()
                if model.isDone {
                    Button("Done") { onDone?() }.buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("enrollment.done")
                } else {
                    Button(model.isRecording ? "Listening…" : "Record") { model.recordUtterance() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isRecording)
                        .accessibilityIdentifier("enrollment.record")
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 420, alignment: .leading)
    }
}

/// R7.2 — there is no enrollment window any more (`DESIGN.md` §5.1, §12.5). This is the shim the
/// composition root still calls: it opens the one window at **Voice** and hands the enrollment view
/// model to that pane, which runs it inline. Nothing here creates an `NSWindow`.
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
