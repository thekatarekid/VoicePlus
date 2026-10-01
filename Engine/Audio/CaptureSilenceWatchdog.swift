import Foundation

/// Why a capture graph that opened successfully is still producing nothing usable — decided from
/// what the tap actually delivered, not from what `engine.start()` returned. Pure; `AudioPipeline`
/// owns one instance per capture and feeds it every processed block.
///
/// The bug this exists for: "Listening · quiet" for ever, no meter, no partial transcript, with a
/// television playing in the room. `AudioPipeline`'s original no-audio watchdog asked only whether
/// *any* block had arrived, and macOS answers that question "yes" in exactly the cases that matter
/// most — a microphone whose TCC grant is missing or was revoked under the running process, a
/// hardware-muted input, and an `AVAudioEngine` whose input node was reconfigured under an
/// installed tap. All three keep the stream open and hand back buffers of **exact zeros** at the
/// full frame rate. One such buffer cancelled the watchdog, so the app reported healthy capture and
/// then sat quiet indefinitely: the level channel published 0, the VAD never saw a speech edge, and
/// the turn latched into `listeningQuiet` with nothing left to move it.
///
/// Exact zero is the whole discrimination. A live analogue input in an anechoic room still dithers
/// the bottom bit; a stream that is being *silenced* (by TCC, by a mute switch, by a dead tap)
/// returns bit-exact zero. So this never fires on a quiet room, and it never fires at all once one
/// non-zero sample has been seen in the capture.
public struct CaptureSilenceWatchdog: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        /// Nothing to report (yet, or ever again for this capture).
        case healthy
        /// Blocks are arriving and every sample of every one of them has been bit-exact zero for
        /// this long. Reported once per capture.
        case digitalSilence(seconds: TimeInterval)
    }

    /// Seconds of unbroken digital silence from the start of the capture before it is called
    /// broken. 0 or less disables the watchdog.
    public var timeout: TimeInterval

    private var silentSeconds: TimeInterval = 0
    /// One non-zero sample disarms the watchdog for the rest of the capture: a microphone that
    /// worked and then went quiet is a quiet room, which `A06`/`listeningQuiet` already covers.
    private var heardSomething = false
    private var reported = false

    public static let defaultTimeout: TimeInterval = 3.0

    public init(timeout: TimeInterval = CaptureSilenceWatchdog.defaultTimeout) {
        self.timeout = timeout
    }

    /// Whether the watchdog can still fire (nothing heard, nothing reported, and it is enabled).
    public var isArmed: Bool { timeout > 0 && !heardSomething && !reported }

    /// Feeds one processed block. `allZero` must be true only when *every* sample was bit-exact 0.
    @discardableResult
    public mutating func note(seconds: TimeInterval, allZero: Bool) -> Verdict {
        guard isArmed else { return .healthy }
        guard allZero else {
            heardSomething = true
            silentSeconds = 0
            return .healthy
        }
        silentSeconds += max(0, seconds)
        guard silentSeconds >= timeout else { return .healthy }
        reported = true
        return .digitalSilence(seconds: silentSeconds)
    }

    /// New capture: armed again, with whatever timeout it now carries.
    public mutating func reset() {
        silentSeconds = 0
        heardSomething = false
        reported = false
    }

    /// The sentence for a `digitalSilence` verdict, naming the device. Catalogue copy owns the
    /// headline (`A05` "No audio is reaching VoicePlus"); this is the detail line and the log entry.
    public static func reason(device: String, seconds: TimeInterval) -> String {
        "No sound is reaching VoicePlus. \(device) is open and delivering audio, but every sample "
            + "has been silent for \(String(format: "%.1f", seconds))s — the input is muted, or macOS "
            + "is silencing it because microphone access is off for this copy of VoicePlus."
    }
}
