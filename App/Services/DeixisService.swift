import Actions
import Foundation
import Shared

/// P3 integration — composition of the input timeline (P3.1), deixis/referent resolvers
/// (P3.3/P3.5) and reverse elicitation (P3.6) behind one seam the app and tests share.
///
/// Lifecycle: `beginCapture()` at hotkey-down pins a `CaptureAlignment` (same clock the
/// timeline events are stamped with) and starts the listen-only event tap when Input
/// Monitoring is granted; `endCapture()` at key release stops the tap; `augment(_:_:)` runs
/// inside `UtteranceLander.land` and injects `contextLine` (+ window text) into
/// `StageContext.extra` for the pipeline / transform, keeping `lastBindings` around for the
/// act path (Phase 4 targets).
public final class DeixisService: @unchecked Sendable {
    public static let contextLineKey = "contextLine"
    public static let windowTextKey = "ax.windowText"

    public let timeline: InputTimeline
    public let clock: TimelineClock
    public let resolver: DeixisResolver
    public let referents = ReferentResolver()
    /// P3.5 providers (AX-backed in the app, static in tests).
    public var participants: ParticipantProviding?
    public var artifacts: ArtifactProviding?
    /// Focused-window text (P3.4) for the pipeline/transform prompt context.
    public var windowText: (() -> String?)?
    /// Fires on every elicitation state change (rings + pill are driven from here).
    public var onElicitationChange: ((ElicitationState) -> Void)?

    public private(set) var alignment: CaptureAlignment?
    public private(set) var lastBindings: [DeixisBinding] = []
    public private(set) var lastReferents: [ReferentBinding] = []
    public private(set) var elicitation = ReverseElicitation()
    private var recorder: EventTapRecorder?
    private let lock = NSLock()

    public init(hitTester: AXHitTesting, timeline: InputTimeline = InputTimeline(),
                clock: TimelineClock = .shared, config: DeixisConfig = DeixisConfig()) {
        self.timeline = timeline
        self.clock = clock
        self.resolver = DeixisResolver(hitTester: hitTester, config: config)
    }

    /// Wire the live CGEvent tap (P3.1). `inkSink` is the overlay; safe to call once after launch.
    public func attachRecorder(normalizer: DisplayNormalizer, inkSink: InkStrokeSink?) {
        let r = EventTapRecorder(timeline: timeline, normalizer: normalizer, clock: clock)
        r.ink.sink = inkSink
        recorder = r
    }

    /// Hotkey-down: alignment starts on the timeline clock; the tap records only while held.
    public func beginCapture(at instant: TimelineInstant? = nil) {
        lock.lock()
        alignment = CaptureAlignment(captureStart: instant ?? clock.now())
        lock.unlock()
        if let recorder, !recorder.isRecording, EventTapRecorder.hasListenAccess {
            do { try recorder.start() } catch { Log.app.warning("deixis: event tap unavailable: \(error)") }
        }
    }

    /// Key release / cancel: stop the tap; the ring buffer keeps its 30 s horizon for resolution.
    public func endCapture() {
        recorder?.stop()
    }

    /// Resolve both kinds of referents for one utterance. Deixis needs the capture alignment;
    /// conversational referents only need the text.
    @discardableResult
    public func resolve(spans: [TranscriptSpan]) -> (deixis: [DeixisBinding], referents: [ReferentBinding]) {
        lock.lock()
        let pinned = alignment
        lock.unlock()
        let d = pinned.map { resolver.resolve(spans: spans, alignment: $0, timeline: timeline) } ?? []
        let r = referents.resolve(spans.joinedText,
                                  participants: participants?.participants() ?? ContextParticipants(),
                                  artifacts: artifacts?.visibleArtifacts() ?? [])
        lock.lock()
        lastBindings = d
        lastReferents = r
        lock.unlock()
        return (d, r)
    }

    /// Context lines for the act path (Phase 4 targets) from the most recent resolution.
    public var actContextLines: [String] {
        lock.lock(); defer { lock.unlock() }
        return lastBindings.map(\.contextLine) + lastReferents.contextLines
    }

    /// `UtteranceLander.contextAugmenter` — inject resolver output + window text into the stage
    /// context, and kick off reverse elicitation when a binding is ambiguous.
    public func augment(_ spans: [TranscriptSpan], _ context: StageContext) -> StageContext {
        var ctx = context
        let (d, r) = resolve(spans: spans)
        let lines = d.map(\.contextLine) + r.contextLines
        if !lines.isEmpty { ctx.extra[Self.contextLineKey] = lines.joined(separator: "; ") }
        if let text = windowText?(), !text.isEmpty { ctx.extra[Self.windowTextKey] = String(text.prefix(2000)) }
        if let ambiguous = d.first(where: { ReverseElicitation.needsElicitation($0) }) {
            ask(about: ambiguous)
        }
        return ctx
    }

    // MARK: - Reverse elicitation (P3.6)

    /// Ring the candidates and ask "which one?". The app glue renders `state` and later feeds
    /// `.point` / `.speech` / `.tick` through `elicit(_:)`.
    public func ask(about binding: DeixisBinding, at instant: TimelineInstant? = nil) {
        let candidates = binding.candidates.prefix(4).enumerated()
            .map { ElicitationCandidate.from($0.element, id: "candidate-\($0.offset)") }
        let state = elicitation.handle(.ask(phrase: binding.word, candidates: Array(candidates),
                                            now: instant ?? clock.now()))
        onElicitationChange?(state)
    }

    @discardableResult
    public func elicit(_ event: ElicitationEvent) -> ElicitationState {
        let state = elicitation.handle(event)
        onElicitationChange?(state)
        return state
    }
}
