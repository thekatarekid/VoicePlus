import Foundation

/// Seconds on the shared monotonic timeline (process-uptime based, unaffected by wall-clock jumps).
public typealias TimelineInstant = TimeInterval

/// One monotonic clock for everything that must line up: ASR audio spans, pointer path, strokes,
/// selection changes. `TimelineClock.shared.now()` is the only stamp source production code uses;
/// tests inject a fake `source`.
public final class TimelineClock: @unchecked Sendable {
    public static let shared = TimelineClock()

    private let source: () -> TimelineInstant

    /// - Parameter source: seconds from an arbitrary fixed origin; must be monotonic.
    public init(source: @escaping () -> TimelineInstant = TimelineClock.uptimeSeconds) {
        self.source = source
    }

    public func now() -> TimelineInstant { source() }

    /// `CLOCK_UPTIME_RAW` — the same mach clock CoreAudio host times and CACurrentMediaTime use.
    public static func uptimeSeconds() -> TimelineInstant {
        TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }
}

/// Maps between timeline instants and `TranscriptSpan.audioRange` seconds (which are relative to
/// the moment audio capture started for the utterance).
public struct CaptureAlignment: Equatable, Sendable {
    public let captureStart: TimelineInstant

    public init(captureStart: TimelineInstant) { self.captureStart = captureStart }

    /// Alignment anchored at the clock's current instant (call when capture actually starts).
    public static func starting(now clock: TimelineClock = .shared) -> CaptureAlignment {
        CaptureAlignment(captureStart: clock.now())
    }

    public func audioSeconds(at instant: TimelineInstant) -> TimeInterval { instant - captureStart }
    public func instant(forAudioSeconds s: TimeInterval) -> TimelineInstant { captureStart + s }

    public func audioRange(for instants: ClosedRange<TimelineInstant>) -> ClosedRange<TimeInterval> {
        audioSeconds(at: instants.lowerBound)...audioSeconds(at: instants.upperBound)
    }

    public func instants(for audioRange: ClosedRange<TimeInterval>) -> ClosedRange<TimelineInstant> {
        instant(forAudioSeconds: audioRange.lowerBound)...instant(forAudioSeconds: audioRange.upperBound)
    }
}
