// VoicePlus original (task R5.1). Not ported code — this is the seam between the Qwen3-ASR
// port in this directory and the pipeline. `Qwen3RefinementSession` implements it with the port;
// `MockRefinementSession` implements it with no weights at all.
import Foundation
import Shared

// MARK: - Stage identity

extension StageID {
    /// The second (refinement) recognition pass. `StageID` is string-backed precisely so a new
    /// stage can be named without touching `Shared/` (see `Shared/Types/StageID.swift`).
    public static let refineQwen3: StageID = "refine.qwen3"
}

// MARK: - Errors

public enum RefinementError: Error, LocalizedError, Equatable {
    /// The refinement backend cannot run on this machine at all: a non-arm64 Mac (Float16 embedding
    /// lookup). macOS 15, which the stateful CoreML decoder needs, is the package floor (V5 J7).
    case unavailableOnThisSystem(String)
    /// No usable weights directory. `searched` are the paths that were looked at, in order.
    case weightsMissing(searched: [String])
    /// The weights directory exists but is not a complete model.
    case weightsIncomplete(path: String, problems: [String])
    /// The pass did not finish inside `deadline`. Callers fall back to pass-1 text (V3 §5.3).
    case deadlineExceeded(Duration)
    case emptyAudio
    /// Anything the backend itself threw, already described.
    case backendFailure(String)

    public var errorDescription: String? {
        switch self {
        case .unavailableOnThisSystem(let why):
            return "Refinement isn\u{2019}t available on this Mac: \(why)"
        case .weightsMissing:
            return "The refinement model isn\u{2019}t installed yet."
        case .weightsIncomplete(_, let problems):
            let detail = problems.count == 1 ? "1 file" : "\(problems.count) files"
            return "The refinement model didn\u{2019}t finish downloading \u{2014} \(detail) are missing or incomplete."
        case .deadlineExceeded:
            return "Refinement ran out of time; the first-pass text was used."
        case .emptyAudio:
            return "There was no audio to refine."
        case .backendFailure(let detail):
            return "Refinement failed: \(detail)"
        }
    }
}

// MARK: - Protocol

/// A second recognition pass over the audio of one segment.
///
/// Contract, in the order the wave-2 `RefineStage` (R5.2) needs it:
/// - `samples` are 16 kHz mono Float32, the same audio pass 1 saw, starting at the segment start.
/// - `context` is plain text put in front of the model as a prompt (screen text, learned lexicon,
///   recent transcript). Never persisted here; never logged.
/// - `deadline` is hard. On timeout the implementation throws `RefinementError.deadlineExceeded`
///   and the caller keeps pass-1 text. Cancelling the calling task cancels the pass.
/// - Returned spans carry `audioRange` **relative to the start of `samples`** and have
///   `StageID.refineQwen3` appended to `provenance`. They do **not** carry a real confidence:
///   see `Refinement.confidenceNotReported`.
public protocol RefinementSession: Sendable {
    func refine(samples: [Float], context: String, deadline: Duration) async throws -> [TranscriptSpan]
}

extension RefinementSession {
    /// Refine the audio behind an existing span, in place.
    ///
    /// This is the shape `RefineStage` wants: `span.audioRange`, `alternates`, `stability` and
    /// `confidence` are the pass-1 span's and survive untouched; only `text` changes, and
    /// `StageID.refineQwen3` is appended to `provenance`. Refinement reports no confidence of its
    /// own, so pass-1's is kept rather than replaced with a made-up number (V3 §5.3).
    public func refine(
        span: TranscriptSpan,
        samples: [Float],
        context: String,
        deadline: Duration
    ) async throws -> TranscriptSpan {
        let refined = try await refine(samples: samples, context: context, deadline: deadline)
        let text = refined.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return span.touched(by: .refineQwen3) }
        return span.rewritten(text, by: .refineQwen3)
    }
}

// MARK: - Shared helpers

public enum Refinement {
    public static let sampleRate = 16_000

    /// What a refined span's `confidence` means: **nothing**. Qwen3-ASR emits no per-span
    /// confidence, and V3 §5.3 says unavailable confidence must be marked, not invented. Stages
    /// that need a confidence must use the pass-1 span's — `refine(span:…)` above does that.
    public static let confidenceNotReported: Float = 0

    public static func seconds(sampleCount: Int) -> TimeInterval {
        Double(sampleCount) / Double(sampleRate)
    }

    /// `0…duration` of the audio handed in. Never an empty or reversed range.
    public static func audioRange(sampleCount: Int) -> ClosedRange<TimeInterval> {
        0...max(seconds(sampleCount: sampleCount), 0)
    }

    /// One span for a whole segment: the model gives text, not word timings, so the span covers
    /// the segment's whole audio range. Re-aligning word timing is R5.2's job.
    public static func span(text: String, sampleCount: Int) -> TranscriptSpan {
        TranscriptSpan(
            text: text,
            confidence: confidenceNotReported,
            audioRange: audioRange(sampleCount: sampleCount),
            provenance: [.refineQwen3]
        )
    }

    /// Run `body` with a hard deadline. On timeout the **caller** gets `.deadlineExceeded` at
    /// once; `body` is not awaited by the caller (V5 Q15).
    ///
    /// CoreML crash hardening: a synchronous `MLModel.prediction` cannot be interrupted, and
    /// releasing or re-specialising the model underneath one is what crashed. So `body` runs in
    /// its own task, registered in `inFlight`, and on timeout it is only *asked* to stop
    /// (cooperative cancellation — the decode loop in `Qwen3AsrManager` checks once per token,
    /// i.e. *between* predictions; the prediction already running always finishes). Anything that
    /// releases or reloads the model must first `await inFlight.drain()`, which returns only once
    /// every such task has finished. A cancelled *caller* propagates `CancellationError`, not a
    /// deadline error, and likewise returns without waiting for the prediction.
    public static func withDeadline<T: Sendable>(
        _ deadline: Duration,
        inFlight: RefinementInFlight = .shared,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard deadline > .zero else { throw RefinementError.deadlineExceeded(deadline) }
        try Task.checkCancellation()
        let work = inFlight.start(body)
        let race = DeadlineRace<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                race.install(continuation)
                let timer = Task {
                    // A cancelled timer means the work already finished: never report a deadline
                    // then (it raced the body's own `finish` and could win, failing a fast body).
                    do { try await Task.sleep(for: deadline) } catch { return }
                    if race.finish(.failure(RefinementError.deadlineExceeded(deadline))) { work.cancel() }
                }
                Task {
                    let outcome: Result<T, Error>
                    do { outcome = .success(try await work.value) } catch { outcome = .failure(error) }
                    race.finish(outcome)
                    timer.cancel()
                }
            }
        } onCancel: {
            if race.finish(.failure(CancellationError())) { work.cancel() }
        }
    }
}

// MARK: - In-flight refinement work (V5 Q15)

/// Every refinement body currently running, so a model release can wait for them.
///
/// `withDeadline` returns to its caller on timeout without waiting for the model; this registry
/// is what keeps the model alive (and un-reloaded) until the prediction that was running has
/// actually finished. Injectable for tests; production code uses `.shared`.
public final class RefinementInFlight: @unchecked Sendable {
    public static let shared = RefinementInFlight()

    private let lock = NSLock()
    private var tasks: [UInt64: Task<Void, Never>] = [:]
    private var nextID: UInt64 = 0

    public init() {}

    /// How many bodies are still running (finished ones deregister themselves).
    public var count: Int { lock.lock(); defer { lock.unlock() }; return tasks.count }

    /// Start `body` in its own unstructured task and register it until it finishes.
    func start<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) -> Task<T, Error> {
        let work = Task { try await body() }
        lock.lock()
        let id = nextID
        nextID &+= 1
        tasks[id] = Task { [weak self] in
            _ = try? await work.value
            self?.remove(id)
        }
        lock.unlock()
        return work
    }

    private func remove(_ id: UInt64) {
        lock.lock(); tasks[id] = nil; lock.unlock()
    }

    /// Wait until no refinement body is running — call before releasing or re-specialising a
    /// model. Never cancels anything; bodies started while draining are waited for too.
    public func drain() async {
        while true {
            lock.lock()
            let pending = Array(tasks.values)
            lock.unlock()
            if pending.isEmpty { return }
            for task in pending { await task.value }
        }
    }
}

/// One Qwen3 CoreML operation at a time, process-wide (V5 Q15).
///
/// Loading/specialising a Qwen3 model while another instance is mid-`prediction` crashed inside
/// MPSGraph (`specializedModuleWithDevice`, SIGSEGV — two sessions, or a session and the prompt
/// probe, in one process). Every model load and every transcription goes through `run`, FIFO. A
/// body whose task was cancelled while queued (a timed-out pass) is skipped, not run.
public actor Qwen3CoreMLGate {
    public static let shared = Qwen3CoreMLGate()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        defer { handOff() }
        try Task.checkCancellation()
        return try await body()
    }

    private func handOff() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

/// First-finisher-wins latch for `withDeadline`: result, timeout or caller cancellation.
private final class DeadlineRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var early: Result<T, Error>?
    private var done = false

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let early {
            lock.unlock()
            continuation.resume(with: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// Resolve the race. Returns `true` only for the call that won it.
    @discardableResult
    func finish(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        guard !done else { lock.unlock(); return false }
        done = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            early = result
            lock.unlock()
        }
        return true
    }
}

// MARK: - Mock

/// A `RefinementSession` with no model behind it: deterministic text, a configurable amount of
/// simulated model time, and the same deadline/cancellation behaviour as the real one. This is
/// what `PipelineTests` should build `RefineStage` against — it needs no 1.2 GB of weights.
public struct MockRefinementSession: RefinementSession {
    /// Fixed output text. `nil` means "synthesize deterministically from the input".
    public let text: String?
    /// Simulated model time. Slept in a cancellable way, so `work > deadline` times out.
    public let work: Duration
    /// Thrown instead of doing any work, for error-path tests.
    public let failure: RefinementError?

    public init(text: String? = nil, work: Duration = .zero, failure: RefinementError? = nil) {
        self.text = text
        self.work = work
        self.failure = failure
    }

    /// Deterministic stand-in transcript: same input, same string, every run and every machine.
    public static func syntheticText(sampleCount: Int, context: String) -> String {
        let seconds = Refinement.seconds(sampleCount: sampleCount)
        var out = String(format: "mock refinement of %.2fs", seconds)
        let words = context.split(whereSeparator: { $0.isWhitespace }).count
        if words > 0 { out += " with \(words) context word\(words == 1 ? "" : "s")" }
        return out
    }

    public func refine(samples: [Float], context: String, deadline: Duration) async throws -> [TranscriptSpan] {
        if let failure { throw failure }
        guard !samples.isEmpty else { throw RefinementError.emptyAudio }
        let count = samples.count
        let body = text
        let sleepFor = work
        return try await Refinement.withDeadline(deadline) {
            if sleepFor > .zero { try await Task.sleep(for: sleepFor) }
            try Task.checkCancellation()
            return [Refinement.span(text: body ?? Self.syntheticText(sampleCount: count, context: context),
                                    sampleCount: count)]
        }
    }
}
