import AppKit
import Combine
import Foundation
import Shared

/// Wires hotkey actions → engine, engine events → pill, finals → history DB.
/// Text "lands" on the pasteboard + history until P1.8's injection stack is integrated (P1.12).
public final class DictationCoordinator {
    public let engine: any EngineProtocol
    public let database: AppDatabase?
    public let pill: PillPanelController
    public var onFinal: (([TranscriptSpan]) -> Void)?
    public private(set) var lastMicQuality: MicQuality?
    public private(set) var handsFree = false
    public private(set) var paused = false
    private var eventTask: Task<Void, Never>?
    private var startedAt = Date()

    public init(engine: any EngineProtocol, database: AppDatabase?, pill: PillPanelController) {
        self.engine = engine
        self.database = database
        self.pill = pill
        pill.model.bind(engineState: engine.statePublisher)
        eventTask = Task { [weak self] in
            for await event in engine.events() {
                guard let self else { return }
                if case .micQuality(let q) = event { await MainActor.run { self.lastMicQuality = q } }
            }
        }
    }

    deinit { eventTask?.cancel() }

    public func setPaused(_ paused: Bool) {
        self.paused = paused
        if paused { cancel() }
    }

    public func handle(_ action: HotkeyStateMachine.Action) {
        guard !paused else { return }
        switch action {
        case .startCapture: start()
        case .finalize: finalize()
        case .cancelCapture: cancel()
        case .enterHandsFree:
            handsFree = true
            pill.model.handsFree = true
        }
    }

    public func start() {
        startedAt = Date()
        Task {
            do { try await engine.start(prewarm: true) } catch {
                Log.app.error("engine start failed: \(error)")
            }
        }
    }

    public func finalize() {
        handsFree = false
        pill.model.handsFree = false
        Task {
            do {
                let spans = try await engine.stop()
                await MainActor.run { self.land(spans) }
            } catch EngineError.notListening {
                // Tap released before the engine finished prewarming — nothing to land.
            } catch {
                Log.app.error("engine stop failed: \(error)")
            }
        }
    }

    public func cancel() {
        handsFree = false
        pill.model.handsFree = false
        Task { await engine.cancel() }
    }

    private func land(_ spans: [TranscriptSpan]) {
        let text = spans.joinedText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if let database {
            let record = DictationRecord(startedAt: startedAt, endedAt: Date(), register: "unknown", route: "dictate",
                                         appBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                         rawText: text, finalText: text,
                                         spansJSON: String(decoding: (try? JSONEncoder().encode(spans)) ?? Data("[]".utf8), as: UTF8.self))
            do { try database.insert(record) } catch { Log.db.error("history insert failed: \(error)") }
        }
        Log.app.info("landed \(spans.count) spans (\(text.count) chars)")
        onFinal?(spans)
    }
}
