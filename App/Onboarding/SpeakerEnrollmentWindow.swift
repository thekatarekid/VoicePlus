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
    public init(model: SpeakerEnrollmentViewModel) { self.model = model }

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
                    Button("Done") { SpeakerEnrollmentWindowController.close() }.buttonStyle(.borderedProminent)
                } else {
                    Button(model.isRecording ? "Listening…" : "Record") { model.recordUtterance() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isRecording)
                        .accessibilityIdentifier("enrollment.record")
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

@MainActor
public enum SpeakerEnrollmentWindowController {
    private static var window: NSWindow?

    public static func show(model: SpeakerEnrollmentViewModel) {
        if let window {
            WindowPlacement.place(window, label: "enrollment (reshow)")
            return
        }
        let host = NSHostingController(rootView: SpeakerEnrollmentView(model: model))
        let w = NSWindow(contentViewController: host)
        w.title = "Voice enrollment"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        WindowPlacement.place(w, label: "enrollment")
        window = w
    }

    public static func close() {
        window?.close()
        window = nil
    }
}
