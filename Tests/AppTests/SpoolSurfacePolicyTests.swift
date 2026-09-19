import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// S12 — Spool across app surfaces (design_v1 §8.9): the table every surface consults, the only
/// activity that may move Spool, and the prototype's own cameo usage (`renderScreen`, `showError`).
@Suite("S12 — Spool surface policy")
struct SpoolSurfacePolicyTests {
    typealias Policy = SpoolSurfacePolicy

    // MARK: The table

    /// Design §8.9, row by row: (motion, resting pose, progress, optional).
    static let expected: [Policy.Surface: (Policy.Motion, SpoolStateKey?, Policy.Progress, Bool)] = [
        .today: (.stillCameo, .ready, .labelled, false),
        .turnDetail: (.stillCameo, .held, .none, false),
        .recoverySheet: (.stillCameo, .held, .none, false),
        .meetingsLibrary: (.staticMark, .ready, .labelled, false),
        .meetingDetail: (.staticMark, .ready, .labelled, false),
        .meetingNotes: (.staticMark, .ready, .labelled, false),
        .meetingAsk: (.staticMark, .ready, .labelled, false),
        .meetingCapture: (.followsCapture, .ready, .labelled, false),
        .dictionaryApps: (.staticMark, .ready, .native, false),
        .settings: (.staticMark, .ready, .native, false),
        .models: (.staticMark, .ready, .native, false),
        .providers: (.staticMark, .ready, .native, false),
        .sync: (.staticMark, .ready, .native, false),
        .updates: (.staticMark, .ready, .native, false),
        .voiceTest: (.followsCapture, .ready, .labelled, false),
        .voiceEnrollment: (.followsCapture, .ready, .labelled, false),
        .privacy: (.stillCameo, .ready, .none, false),
        .onboarding: (.followsCapture, .ready, .labelled, false),
        .statusMenu: (.glyph, nil, .none, false),
        .correctionPopover: (.stillCameo, .correcting, .none, true),
    ]

    @Test func everySurfaceHasItsDesignRow() {
        #expect(Set(Self.expected.keys) == Set(Policy.Surface.allCases))
        for surface in Policy.Surface.allCases {
            let row = Policy.treatment(for: surface)
            let want = Self.expected[surface]!
            #expect(row.surface == surface)
            #expect(row.motion == want.0, "\(surface) motion")
            #expect(row.restingKey == want.1, "\(surface) resting pose")
            #expect(row.progress == want.2, "\(surface) progress")
            #expect(row.optional == want.3, "\(surface) optional")
        }
    }

    // MARK: Allowed motion

    @Test func onlyRealCaptureOnACaptureSurfaceEverMovesSpool() {
        for surface in Policy.Surface.allCases {
            let row = Policy.treatment(for: surface)
            for activity in Policy.Activity.allCases {
                for reading in [false, true] {
                    guard let look = Policy.appearance(on: surface, activity: activity, readingLongForm: reading) else {
                        #expect(row.motion == .glyph, "\(surface) draws nothing only as the glyph")
                        continue
                    }
                    let mayMove = row.motion == .followsCapture && activity == .capturing && !reading
                    #expect(look.animates == mayMove, "\(surface) · \(activity) · reading \(reading)")
                    // Live poses (turning reels, audio tape) only for open capture.
                    if SpoolPoseTable.isLive(look.key) { #expect(activity == .capturing, "\(surface) live pose while \(activity)") }
                    // No celebration, no feeding tape on a window surface.
                    #expect(!Policy.pillOnlyKeys.contains(look.key), "\(surface) drew \(look.key)")
                }
            }
        }
    }

    @Test func loadingNeverSpinsAndLongFormReadingStaysStill() {
        for surface in Policy.Surface.allCases {
            #expect(Policy.appearance(on: surface, activity: .loading)?.animates != true, "\(surface) spun for loading")
            #expect(Policy.appearance(on: surface, activity: .capturing, readingLongForm: true)?.animates != true)
        }
        #expect(Policy.appearance(on: .today, activity: .loading) == .init(key: .ready, animates: false))
        #expect(Policy.appearance(on: .models, activity: .loading) == .init(key: .ready, animates: false))
    }

    @Test func stillAndStaticSurfacesKeepTheirPoseWhateverHappens() {
        for surface in Policy.Surface.allCases where [.stillCameo, .staticMark].contains(Policy.treatment(for: surface).motion) {
            for activity in Policy.Activity.allCases {
                let look = Policy.appearance(on: surface, activity: activity)
                #expect(look?.animates == false)
                let want: SpoolStateKey? = surface == .privacy && activity == .muted ? .muted : Policy.treatment(for: surface).restingKey
                #expect(look?.key == want, "\(surface) · \(activity)")
            }
        }
        // Privacy / mute: the closed-shutter pose beside hard mute.
        #expect(Policy.appearance(on: .privacy, activity: .muted) == .init(key: .muted, animates: false))
        #expect(SpoolPoseTable.overlays(for: .muted).contains(.shutterLatch))
    }

    @Test func captureSurfacesMirrorOnlyActualCapture() {
        // Voice test / enrollment: moves only during capture, parks while analysing.
        for surface: Policy.Surface in [.voiceTest, .voiceEnrollment] {
            #expect(Policy.appearance(on: surface, activity: .idle) == .init(key: .ready, animates: false))
            #expect(Policy.appearance(on: surface, activity: .capturing) == .init(key: .listening, animates: true))
            #expect(Policy.appearance(on: surface, activity: .analyzing) == .init(key: .finishing, animates: false))
            #expect(Policy.appearance(on: surface, activity: .muted) == .init(key: .muted, animates: false))
        }
        // Meeting capture panel: reels and tape only while capture is open; pause closes it.
        #expect(Policy.appearance(on: .meetingCapture, activity: .capturing) == .init(key: .meeting, animates: true))
        #expect(Policy.appearance(on: .meetingCapture, activity: .paused) == .init(key: .paused, animates: false))
        #expect(Policy.appearance(on: .meetingCapture, activity: .analyzing) == .init(key: .notes, animates: false))
        #expect(Policy.appearance(on: .meetingCapture, activity: .idle) == .init(key: .ready, animates: false))
        // Onboarding: a still cameo; moves only during the real dictation test.
        #expect(Policy.appearance(on: .onboarding, activity: .idle) == .init(key: .ready, animates: false))
        #expect(Policy.appearance(on: .onboarding, activity: .capturing) == .init(key: .listening, animates: true))
        // Status menu: the glyph only. Correction popover: an optional still attentive cameo.
        #expect(Policy.appearance(on: .statusMenu, activity: .capturing) == nil)
        #expect(Policy.appearance(on: .correctionPopover) == .init(key: .correcting, animates: false))
    }

    // MARK: The prototype's cameo usage

    private struct Copy: Decodable { let emptyCopy: [String: [String]] }
    private struct Pose: Decodable { let key: String }
    private struct Spec: Decodable { let errorPoses: [String: Pose] }

    private static func fixture<T: Decodable>(_ path: String, as type: T.Type) throws -> T {
        let dir = try #require(AppPaths.fixturesDirectory())
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: dir.appendingPathComponent(path)))
    }

    @Test func screensAreThePrototypePickerScreens() throws {
        let copy = try Self.fixture("design/design_copy.json", as: Copy.self)
        #expect(Set(copy.emptyCopy.keys) == Set(Policy.Screen.allCases.map(\.rawValue)))
    }

    @Test func emptyAndLoadingUseReadyTodayPrivacyReadyTurnRecoveryHeld() {
        for screen in Policy.Screen.allCases {
            #expect(Policy.cameo(screen: screen, variant: .empty) == .init(key: .ready, note: nil))
            #expect(Policy.cameo(screen: screen, variant: .loading) == .init(key: .ready, note: nil))
            #expect(Policy.cameo(screen: screen, variant: .error) == nil, "a whole-screen error is a banner, no cameo")
            let content = Policy.cameo(screen: screen, variant: .content)
            #expect(Policy.cameo(screen: screen, variant: .partial) == content)
            switch screen {
            case .today, .privacy: #expect(content == .init(key: .ready, note: Policy.readyNote))
            case .turn, .recovery: #expect(content == .init(key: .held, note: Policy.heldNote))
            case .onboarding: #expect(content == .init(key: .ready, note: nil), "the step card's still cameo")
            default: #expect(content == nil, "\(screen) content draws no cameo")
            }
        }
    }

    @Test func surfaceNotesAreVerbatimFromThePrototype() throws {
        let dir = try #require(AppPaths.fixturesDirectory())
        let html = try String(contentsOf: dir.deletingLastPathComponent().appendingPathComponent("design/design_v1.html"), encoding: .utf8)
        #expect(html.contains(Policy.readyNote))
        #expect(html.contains(Policy.heldNote))
        #expect(html.contains("const pose=['turn','recovery'].includes(screen)?'held':'ready'"))
    }

    @Test func everyErrorNoticeUsesItsErrorPose() throws {
        let spec = try Self.fixture("spool/spool_spec.json", as: Spec.self)
        #expect(Set(spec.errorPoses.keys) == Set(RecoveryID.allCases.map(\.rawValue)))
        for id in RecoveryID.allCases {
            let want = try #require(spec.errorPoses[id.rawValue]).key
            #expect(Policy.cameo(for: id).rawValue == want, "\(id)")
        }
        // Spot checks from the prototype table.
        #expect(Policy.cameo(for: .D06) == .unconfirmed)
        #expect(Policy.cameo(for: .D10) == .correcting)
        #expect(Policy.cameo(for: .K05) == .muted)
        #expect(Policy.cameo(for: .P01) == .blocked)
    }
}
