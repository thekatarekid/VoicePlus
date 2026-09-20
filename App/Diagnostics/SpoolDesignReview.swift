import AppKit
import Combine
import Engine
import Shared
import SwiftUI

/// Explicit, isolated visual QA entry point. Uses the production panel, model and artwork;
/// never starts AppContainer, microphone capture, destination insertion or user-data persistence.
/// Launch the installed bundle with --design-v3-review. Normal launch never enters this mode.
final class SpoolDesignReview: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var selection = "listening"
    @Published var longText = false
    private(set) var pill: PillPanelController!
    private var window: NSWindow?
    private var presence: PresenceIndicatorController?
    private var timer: Timer?
    private var began = Date()
    static let keys = ["idle", "ready", "starting", "listening", "quiet", "latched", "finishing", "preview", "uncertain", "inserting", "inserted", "held", "unconfirmed", "partial", "micWarning", "cancelled", "muted", "unavailable", "editing", "undo", "meeting", "paused", "notes", "error", "correcting", "blocked"]
    var text: String {
        "Can we meet with Mira on Friday?" + (longText ? " I would like to go through the launch checklist, confirm who owns each task, and leave enough time to discuss the customer feedback. Please bring the latest designs and the revised timeline. We can make the remaining decisions together, then send a clear summary to everyone who could not join. There is no need to rush the review; I would rather resolve the open questions before we announce the date." : "")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        pill = PillPanelController()
        pill.model.keyLabel = { "Right Control" }
        pill.model.destinationProvider = { "Mail" }
        pill.model.onApplyDraft = { [weak self] text, mapping, spans in
            guard let self else { return false }
            self.pill.model.setFinalSpans(spans, text: text)
            self.pill.model.present(.finalPreview(FinalPreviewInfo(text: text, uncertainCount: mapping.count,
                dwellRemaining: 0.6, paused: true, manual: true, destination: "Mail")))
            return true
        }
        pill.model.onApplyRetainedDraft = { _, _, _, _ in true }
        let presence = PresenceIndicatorController()
        presence.readyHint = { "Hold or Double Tap Right Control to dictate" }
        presence.bind(pill: pill.model, engineStates: Empty<EngineState, Never>().eraseToAnyPublisher(), mute: nil)
        presence.start()
        self.presence = presence
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 490),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "VoicePlus · Native V3 design review"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SpoolDesignReviewControls(review: self))
        window.center()
        self.window = window
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let controls = NSMenuItem(title: "Show design controls", action: #selector(showControls), keyEquivalent: "1")
        controls.target = self
        appMenu.addItem(controls)
        appMenu.addItem(NSMenuItem(title: "Quit review", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        show()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, ["listening", "latched", "meeting"].contains(self.selection) else { return }
            let t = Date().timeIntervalSince(self.began)
            self.pill.model.push(capturedLevel: Float(0.4 + 0.2 * sin(t * 4) + 0.12 * sin(t * 9)))
        }
    }

    @objc func showControls() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func inspectNotch() {
        // Hide only the diagnostic controller so computer-use inspection can target the actual
        // production panel, without moving it or changing its content/geometry.
        window?.orderOut(nil)
        NSApp.windows.first { $0 is NSPanel && $0.isVisible && !$0.ignoresMouseEvents }?.makeKeyAndOrderFront(nil)
    }

    func show() {
        guard let pill else { return }
        began = Date()
        pill.model.hide()
        // Production reducer/context receives a labelled synthetic capture for visual inspection.
        pill.model.apply(.listening(level: 0.55))
        pill.model.apply(.previewing(text: text))
        let state: PillState
        switch selection {
        case "idle": state = .idle
        case "ready": state = .ready(hint: "Hold or Double Tap Right Control to dictate")
        case "starting": state = .starting
        case "listening": state = .preview(text: text)
        case "quiet": state = .listeningQuiet
        case "latched": state = .latched(elapsed: 6)
        case "finishing": state = .finishing(elapsedWarning: false)
        case "preview", "uncertain": state = .finalPreview(FinalPreviewInfo(text: text, uncertainCount: selection == "uncertain" ? 1 : 0, dwellRemaining: 0.6, paused: true, manual: true, destination: "Mail"))
        case "inserting": state = .inserting(text: text)
        case "inserted": state = .landed(LandedPillInfo(text: text, verified: true))
        case "held": state = .held(HeldPillInfo(text: text, destination: "Mail", reason: "destination changed"))
        case "unconfirmed": state = .landed(LandedPillInfo(text: text, verified: false))
        case "partial": state = .landedPartial(text: text)
        case "micWarning": state = .warning(MicQuality(snr: 8, clipping: 0, lowLevel: false, verdict: .poor))
        case "cancelled": state = .cancelled
        case "muted": state = .muted
        case "unavailable": state = .unavailable(reason: "No speech model")
        case "editing": state = .editing
        case "undo": state = .undoAvailable
        case "meeting": state = .meeting(MeetingPillInfo(phase: .recording, elapsed: 84))
        case "paused": state = .meeting(MeetingPillInfo(phase: .paused, elapsed: 84))
        case "notes": state = .meeting(MeetingPillInfo(phase: .preparingNotes, elapsed: 84))
        case "correcting": state = .correcting
        case "blocked": state = .error(message: RecoveryCatalog.entry(.P01).headline)
        default: state = .error(message: RecoveryCatalog.entry(.T01).headline)
        }
        if selection != "listening" { pill.model.present(state) }
        if ["uncertain", "held", "unconfirmed", "partial", "inserted"].contains(selection) {
            let spans = text.split(separator: " ").map { word in
                TranscriptSpan(text: String(word), confidence: word == "Mira" ? 0.3 : 0.95, audioRange: 0...1,
                               alternates: word == "Mira" ? [Alternate(text: "Meera", score: 0.8, source: .beam)] : [])
            }
            pill.model.setFinalSpans(spans, text: text)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct SpoolDesignReviewControls: View {
    @ObservedObject var review: SpoolDesignReview
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Native Spool / V3").font(.system(size: 26, weight: .semibold))
            Text("Production notch, artwork and motion. Visual inspection only — no microphone, writes or saved corrections.")
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 8) {
                ForEach(SpoolDesignReview.keys, id: \.self) { key in
                    Button(key) { review.selection = key; review.show() }
                        .buttonStyle(.bordered)
                        .tint(review.selection == key ? .orange : .gray)
                        .accessibilityIdentifier("spool-review-" + key)
                }
            }
            Toggle("Long paragraph", isOn: $review.longText).onChange(of: review.longText) { _, _ in review.show() }
            Text("Inspect the actual notch at the top of the screen. Change states here; scroll inside the notch. Close this window to end review mode.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Text("State: " + review.selection).monospaced(); Spacer(); Button("Inspect notch") { review.inspectNotch() }; Button("Quit review") { NSApp.terminate(nil) } }
            Text("⌘1 returns to these controls.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 640, height: 490)
    }
}
