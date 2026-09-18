import Foundation

/// S1 — the reel angle (build doc S1.4, S1.6 rules 2–3). External state, accumulated by the host each
/// frame and never reset between states: preview, held, paused and every other still pose keep the
/// angle the last moving state left, and quiet pauses resume from it (design §3.1, §11.1).
struct SpoolReelIntegrator: Equatable, Sendable {
    /// Degrees; negative = counterclockwise as viewed from the front. Both reels share it.
    private(set) var angle: Double = 0

    /// The prototype's listening speed, °/s counterclockwise.
    static let listeningSpeed = 150.0
    /// Inserting turns clockwise at 440 °/s …
    static let insertingSpeed = 440.0
    /// … until 1.05 s.
    static let insertingWindow = 1.05
    /// Finishing decelerates from 150 °/s to 0 over 0.55 s, still counterclockwise.
    static let finishingWindow = 0.55
    /// Frames further apart than this advance as if 50 ms had passed.
    static let dtClamp = 0.05

    init(angle: Double = 0) { self.angle = angle }

    /// Live-state speed. The prototype's simulation turns at a flat 150 °/s; the product modulates it
    /// by speech activity, `150 · (0.6 + 0.4 · level)` (design §11).
    static func liveSpeed(level: Double?) -> Double {
        guard let level else { return listeningSpeed }
        return listeningSpeed * (0.6 + 0.4 * SpoolMath.clamp(level.isNaN ? 0 : level))
    }

    /// One frame of `drawWave()`.
    ///
    /// - Parameters:
    ///   - t: seconds since the state began (not remapped), at this frame.
    ///   - dt: seconds since the previous frame (0 on the first frame after a state change).
    ///   - level: smoothed capture level for the product; `nil` reproduces the prototype.
    mutating func advance(_ key: SpoolStateKey, t: Double, dt rawDt: Double, level: Double? = nil, reduceMotion: Bool = false) {
        guard !reduceMotion else { return }
        let dt = SpoolMath.min(SpoolMath.max(rawDt.isNaN ? 0 : rawDt, 0), Self.dtClamp)
        if SpoolPoseTable.isLive(key) {
            angle -= Self.liveSpeed(level: level) * dt
        } else if key == .finishing && t < Self.finishingWindow {
            angle -= Self.listeningSpeed * (1 - t / Self.finishingWindow) * dt
        } else if key == .inserting && t < Self.insertingWindow {
            angle += Self.insertingSpeed * dt
        }
    }
}

/// S1.6 rule 1 — the capture level that drives the tape: a one-pole follower with a 40 ms attack and a
/// 250 ms release, so the tape rises with speech and settles flat when the microphone goes quiet.
struct SpoolLevelSmoother: Equatable, Sendable {
    static let attack = 0.040
    static let release = 0.250

    private(set) var value: Double = 0

    init(value: Double = 0) { self.value = value }

    /// Moves toward `target` (clamped to 0…1) over `dt` seconds and returns the smoothed level.
    @discardableResult
    mutating func advance(toward target: Double, dt: Double) -> Double {
        let goal = SpoolMath.clamp(target.isNaN ? 0 : target)
        guard dt > 0 else { return value }
        let tau = goal > value ? Self.attack : Self.release
        value += (goal - value) * (1 - Foundation.exp(-dt / tau))
        return value
    }
}

/// S1.6 rule 2 — "silence parks the reels" (design §6 C2): `listening` shows as `quiet` after 1.5 s of
/// VAD silence, and speech returns it to `listening`. `quiet` is not a live state, so the reels hold
/// their angle while it lasts and resume from it.
struct SpoolSilenceTracker: Equatable, Sendable {
    static let quietAfter = 1.5

    /// When the current silence began, or `nil` while speech is present.
    private(set) var silentSince: TimeInterval?

    init() {}

    /// Feed every VAD decision (`speech`) with its timestamp in seconds.
    mutating func note(speech: Bool, at time: TimeInterval) {
        if speech {
            silentSince = nil
        } else if silentSince == nil {
            silentSince = time
        }
    }

    /// Forget the silence (a new turn or a key other than listening).
    mutating func reset() { silentSince = nil }

    /// The key Spool should draw for `key` at `time`: `listening` becomes `quiet` once the silence has
    /// lasted 1.5 s; every other key passes through.
    func displayedKey(_ key: SpoolStateKey, at time: TimeInterval) -> SpoolStateKey {
        Self.displayedKey(key, silence: silentSince.map { time - $0 } ?? 0)
    }

    static func displayedKey(_ key: SpoolStateKey, silence: TimeInterval) -> SpoolStateKey {
        key == .listening && silence >= quietAfter ? .quiet : key
    }
}
