import Engine
import Foundation

/// S12 — where Spool may appear outside the pill, and how it may move there (design_v1 §8.9, §10
/// "Spool recovery rules", §11.1).
///
/// One table every window, panel, popover and onboarding surface consults instead of choosing a pose
/// of its own. The rules it encodes:
///  · Spool moves only while real microphone capture is open on that surface. Loading, downloads,
///    network calls and background analysis never make it move: progress is labelled or native UI.
///  · Everywhere else it is a still cameo or the static brand mark; the status menu uses only the
///    monochrome glyph (S6, `MenuBarGlyph`).
///  · It never plays beside long-form reading, and there are no pet mechanics, skins, celebratory
///    poses or confetti: no window surface ever draws a satisfied/inserting pose.
///
/// The prototype's own usage is matched exactly (`design_v1.html` `renderScreen` / `showError`):
/// empty and loading screens use the `ready` cameo; Today and Privacy content use `ready`, Turn detail
/// and Recovery use `held`; each error notice uses `errorPoses[id]` from `spool_spec.json`.
enum SpoolSurfacePolicy {
    // MARK: Surfaces

    /// Every app surface that may show Spool (design §8.9's rows, one case per surface).
    enum Surface: String, CaseIterable, Sendable {
        /// Today and its empty history: one small still cameo beside the hold hint.
        case today
        case turnDetail
        case recoverySheet
        case meetingsLibrary
        case meetingDetail
        case meetingNotes
        case meetingAsk
        /// The meeting capture / expanded panel.
        case meetingCapture
        case dictionaryApps
        case settings
        case models
        case providers
        case sync
        case updates
        case voiceTest
        case voiceEnrollment
        /// Privacy, including the hard-mute status.
        case privacy
        case onboarding
        case statusMenu
        case correctionPopover
    }

    /// How Spool may move on a surface.
    enum Motion: String, Sendable {
        /// A still cameo in one pose. Never animates; never spins for loading.
        case stillCameo
        /// The small static brand mark (the still `ready` face). Nothing on the surface moves it.
        case staticMark
        /// Still at rest; reels and tape move only while real capture is open for this surface.
        case followsCapture
        /// The monochrome cassette outline glyph only (S6); the character is never drawn.
        case glyph
    }

    /// How a surface shows its own background work. Never by spinning Spool's reels or tape.
    enum Progress: String, Sendable {
        case none
        /// Labelled progress UI ("Preparing notes…", "Answering…").
        case labelled
        /// Native progress indicators (downloads, network calls, verification).
        case native
    }

    /// What is actually happening on a surface. `capturing` is the only activity that can move Spool.
    enum Activity: String, CaseIterable, Sendable {
        case idle
        /// Background loading or network work.
        case loading
        /// Real microphone capture is open for this surface (a test, enrollment, a meeting).
        case capturing
        /// Capture closed, results being analysed or prepared.
        case analyzing
        /// Meeting capture paused.
        case paused
        /// Hard mute is on.
        case muted
    }

    /// One row of the table.
    struct Treatment: Equatable, Sendable {
        let surface: Surface
        let motion: Motion
        /// The pose drawn at rest; `nil` only for the glyph.
        let restingKey: SpoolStateKey?
        let progress: Progress
        /// The correction popover's cameo may be left out entirely.
        let optional: Bool
    }

    /// What a surface draws right now.
    struct Appearance: Equatable, Sendable {
        let key: SpoolStateKey
        /// True only while real capture is open on a surface whose Spool follows capture.
        let animates: Bool
    }

    /// The design §8.9 table.
    static func treatment(for surface: Surface) -> Treatment {
        switch surface {
        case .today:
            return Treatment(surface: surface, motion: .stillCameo, restingKey: .ready, progress: .labelled, optional: false)
        case .turnDetail, .recoverySheet:
            return Treatment(surface: surface, motion: .stillCameo, restingKey: .held, progress: .none, optional: false)
        case .meetingsLibrary, .meetingDetail, .meetingNotes, .meetingAsk:
            return Treatment(surface: surface, motion: .staticMark, restingKey: .ready, progress: .labelled, optional: false)
        case .meetingCapture:
            return Treatment(surface: surface, motion: .followsCapture, restingKey: .ready, progress: .labelled, optional: false)
        case .dictionaryApps, .settings, .models, .providers, .sync, .updates:
            return Treatment(surface: surface, motion: .staticMark, restingKey: .ready, progress: .native, optional: false)
        case .voiceTest, .voiceEnrollment:
            return Treatment(surface: surface, motion: .followsCapture, restingKey: .ready, progress: .labelled, optional: false)
        case .privacy:
            return Treatment(surface: surface, motion: .stillCameo, restingKey: .ready, progress: .none, optional: false)
        case .onboarding:
            return Treatment(surface: surface, motion: .followsCapture, restingKey: .ready, progress: .labelled, optional: false)
        case .statusMenu:
            return Treatment(surface: surface, motion: .glyph, restingKey: nil, progress: .none, optional: false)
        case .correctionPopover:
            return Treatment(surface: surface, motion: .stillCameo, restingKey: .correcting, progress: .none, optional: true)
        }
    }

    /// What `surface` draws for `activity`. `nil` means the character is not drawn (the status menu
    /// shows the glyph instead). `readingLongForm` — a transcript or note open for reading — keeps
    /// Spool still whatever else is happening.
    static func appearance(on surface: Surface, activity: Activity = .idle, readingLongForm: Bool = false) -> Appearance? {
        let row = treatment(for: surface)
        guard let resting = row.restingKey else { return nil }
        let key: SpoolStateKey
        switch row.motion {
        case .glyph:
            return nil
        case .stillCameo, .staticMark:
            // Privacy / mute: the closed-shutter pose beside hard mute; permission and retention
            // text stay authoritative next to it.
            key = (surface == .privacy && activity == .muted) ? .muted : resting
        case .followsCapture:
            key = followingKey(on: surface, activity: activity, resting: resting)
        }
        let animates = row.motion == .followsCapture && activity == .capturing && !readingLongForm
        return Appearance(key: key, animates: animates)
    }

    /// The pose of a capture-following surface. Only real capture uses a live pose; analysing parks
    /// the reels, a paused meeting shows the pause bars, mute closes the shutters.
    private static func followingKey(on surface: Surface, activity: Activity, resting: SpoolStateKey) -> SpoolStateKey {
        switch activity {
        case .idle, .loading: return resting
        case .muted: return .muted
        case .capturing: return surface == .meetingCapture ? .meeting : .listening
        case .paused: return surface == .meetingCapture ? .paused : resting
        case .analyzing: return surface == .meetingCapture ? .notes : .finishing
        }
    }

    /// Poses that celebrate or feed text. The pill uses them for a real insertion; no window surface
    /// ever does (design §8.9: no pet mechanics, skins or confetti).
    static let pillOnlyKeys: Set<SpoolStateKey> = [.inserting, .inserted, .undo, .preview, .uncertain]

    // MARK: Prototype screens (`renderScreen`)

    /// The prototype's screen picker ids (`design_copy.json` › `emptyCopy` keys).
    enum Screen: String, CaseIterable, Sendable {
        case today, turn, meetings
        case meetingDetail = "meeting-detail"
        case dictionary, voice, privacy, settings, shortcuts, models, services, onboarding, menu, recovery
    }

    /// The prototype's screen variants. `partial` is content with a scoped banner above it.
    enum Variant: String, CaseIterable, Sendable {
        case content, empty, loading, error, partial
    }

    /// A still cameo and the one line that accompanies it.
    struct Cameo: Equatable, Sendable {
        let key: SpoolStateKey
        /// The sentence beside the cameo (`spool-surface-note`), when the screen shows one.
        let note: String?
    }

    /// `spool-surface-note` copy, verbatim from the prototype.
    static let readyNote = "Spool · Ready when you are. Microphone closed."
    static let heldNote = "Your text stays held until you resolve it."

    /// The cameo a screen draws: empty and loading screens use `ready`; Today and Privacy content use
    /// `ready`, Turn detail and Recovery use `held`, each with its note; onboarding's step card uses
    /// the still `ready` cameo with no note (the step text is its copy); a whole-screen error is a
    /// banner with no cameo; every other content screen draws none. `partial` is the content with a
    /// banner above it, so it draws what the content draws.
    static func cameo(screen: Screen, variant: Variant) -> Cameo? {
        switch variant {
        case .empty, .loading:
            return Cameo(key: .ready, note: nil)
        case .error:
            return nil
        case .content, .partial:
            switch screen {
            case .today, .privacy: return Cameo(key: .ready, note: readyNote)
            case .turn, .recovery: return Cameo(key: .held, note: heldNote)
            case .onboarding: return Cameo(key: .ready, note: nil)
            default: return nil
            }
        }
    }

    /// The still pose beside a recovery notice: `errorPoses[id].key`, through the S9 catalogue.
    static func cameo(for recovery: RecoveryID) -> SpoolStateKey {
        SpoolStateKey(rawValue: RecoveryCatalog.entry(recovery).poseKey) ?? .error
    }
}
