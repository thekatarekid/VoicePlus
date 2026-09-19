import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// S2 — every pill state's rendered status, helper and button labels equal the verified prototype's
/// (`Fixtures/design/design_copy.json` › `pill`, generated from `design/design_v1.html`), after the three
/// runtime substitutions: the sample transcript → the real text, "Mail" → the real destination,
/// "Right Control" → the configured key. The timer is the real elapsed time.
@Suite("S2 — design copy parity (pill)")
struct DesignCopyParityTests {
    struct Button: Equatable, CustomStringConvertible {
        var label: String
        var action: String
        var primary: Bool
        var description: String { "\(label)/\(action)\(primary ? "*" : "")" }
    }

    struct Entry {
        var status: String?
        var text: String?
        var strings: [String]
        var buttons: [Button]
        var notice: Bool
        var tone: String?
    }

    static func fixture() throws -> [String: Entry] {
        let dir = try #require(AppPaths.fixturesDirectory())
        let data = try Data(contentsOf: dir.appendingPathComponent("design/design_copy.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pill = try #require(root["pill"] as? [String: [String: Any]])
        return pill.mapValues { raw in
            let buttons = (raw["buttons"] as? [[String: Any]] ?? []).map {
                Button(label: $0["label"] as? String ?? "", action: $0["action"] as? String ?? "",
                       primary: $0["primary"] as? Bool ?? false)
            }
            return Entry(status: raw["status"] as? String, text: raw["text"] as? String,
                         strings: raw["strings"] as? [String] ?? [], buttons: buttons,
                         notice: raw["notice"] as? Bool ?? false, tone: raw["tone"] as? String)
        }
    }

    static let t0 = Date(timeIntervalSince1970: 50_000)
    static let sample = "Can we meet with Mira on Friday?"

    /// The prototype's own context: destination "Mail", key "Right Control", 6 s into the turn.
    static func prototypeContext(live: String = sample, uncertain: Int = 0) -> PillTurnContext {
        PillTurnContext(keyLabel: "Right Control", destination: "Mail", startedAt: t0, now: t0.addingTimeInterval(6),
                        liveText: live, captureOpen: true, uncertainCount: uncertain)
    }

    static func buttons(_ content: PillContent) -> [Button] {
        content.buttons.map { Button(label: $0.label, action: $0.action.rawValue, primary: $0.primary) }
    }

    /// State key → the rendered content in the prototype's context, and the fixture helper it must draw.
    static func rendered() -> [(key: String, content: PillContent, helper: String?)] {
        let c = prototypeContext()
        let final = FinalPreviewInfo(text: sample, dwellRemaining: 0.9, manual: true, destination: "Mail")
        let uncertain = FinalPreviewInfo(text: sample, uncertainCount: 1, dwellRemaining: 1.8, manual: true, destination: "Mail")
        var inserted = c
        inserted.uncertainCount = 1
        var closed = c
        closed.captureOpen = false
        return [
            ("starting", PillContent.make(.starting, context: PillTurnContext(keyLabel: "Right Control", destination: "Mail")),
             "Recording starts when the microphone is open"),
            ("listening", PillContent.make(.listening(level: 0.4), context: c), "Release Right Control to finish"),
            ("quiet", PillContent.make(.listeningQuiet, context: c), "Still listening while you hold"),
            ("latched", PillContent.make(.latched(elapsed: 6), context: c), "Tap Right Control to finish"),
            ("finishing", PillContent.make(.finishing(elapsedWarning: false), context: closed),
             "Microphone closed · nothing inserted yet"),
            ("preview", PillContent.make(.finalPreview(final), context: closed), "Final text · insert when ready"),
            ("uncertain", PillContent.make(.finalPreview(uncertain), context: closed), "Review mode · insert when ready"),
            ("inserting", PillContent.make(.inserting(text: sample), context: closed), "Same text · one insertion attempt"),
            ("inserted", PillContent.make(.landed(LandedPillInfo(text: sample, verified: true)), context: inserted),
             "1 word to review in the field"),
            ("held", PillContent.make(.held(HeldPillInfo(text: sample, destination: "Mail", reason: "destination changed")),
                                      context: closed), "Nothing was typed into the new field"),
            ("unconfirmed", PillContent.make(.landed(LandedPillInfo(text: sample, verified: false)), context: closed),
             "Check the field before trying again"),
            ("partial", PillContent.make(.landedPartial(text: sample), context: closed),
             "Review both versions to avoid duplicate text"),
            ("warning", PillContent.make(.warning(MicQuality(snr: 8, clipping: 0, lowLevel: false, verdict: .poor)), context: c),
             "Keep speaking, or check your microphone"),
            ("cancelled", PillContent.make(.cancelled, context: closed), "You can start a new dictation"),
            ("muted", PillContent.make(.muted, context: PillTurnContext()), "Unmute when you are ready"),
            ("unavailable", PillContent.make(.unavailable(reason: "No speech model"), context: PillTurnContext()),
             "No usable recognizer is ready"),
            ("editing", PillContent.make(.transform(TransformPillInfo(editingWords: 18, stage: .editing)), context: closed),
             "Microphone closed · original text unchanged"),
            ("undo", PillContent.make(.undoAvailable, context: closed), "Undo only while the edited range still matches"),
            ("meeting", PillContent.make(.meeting(MeetingPillInfo(phase: .recording, elapsed: 724)), context: PillTurnContext()),
             "Capture is separate from dictation"),
            ("paused", PillContent.make(.meeting(MeetingPillInfo(phase: .paused, elapsed: 724)), context: PillTurnContext()),
             "Resume when you are ready"),
            ("notes", PillContent.make(.meeting(MeetingPillInfo(phase: .preparingNotes, elapsed: 724)), context: PillTurnContext()),
             "No microphone is recording"),
            ("correcting", PillContent.make(.correcting, context: closed), "Keep the spelling or replace the verified word"),
            ("blocked", PillContent.blocked(), "Nothing was recorded or typed"),
            ("error", PillContent.make(.error(message: DeliveryCopy.couldNotType), context: closed),
             "These words were recovered. Nothing inserted."),
        ]
    }

    @Test func everyTurnStateMatchesTheFixture() throws {
        let fixture = try Self.fixture()
        let rows = Self.rendered()
        // Every fixture state except the chin and the hint (tested below) is rendered here.
        #expect(Set(rows.map(\.key)).union(["idle", "ready"]) == Set(fixture.keys))
        for row in rows {
            let entry = try #require(fixture[row.key], "\(row.key)")
            let content = row.content
            #expect(content.designKey == row.key, "\(row.key) drew \(content.designKey)")
            // Status: the fixture's, verbatim ("Ready for Mail · " + the review count for F2).
            let status = try #require(entry.status)
            if row.key == "uncertain" {
                #expect(content.status == status + "1 word to review")
                #expect(entry.strings.contains("1 word to review"))
            } else {
                #expect(content.status == status, "\(row.key)")
            }
            // Helper: a sentence the prototype draws for this state.
            if let helper = row.helper {
                #expect(content.helper == helper, "\(row.key) helper")
                #expect(entry.strings.contains(helper), "\(row.key): \(helper) not in the fixture")
            }
            // Buttons: label, action and primary, in order.
            #expect(Self.buttons(content) == entry.buttons, "\(row.key) buttons \(Self.buttons(content))")
            #expect(content.notice == entry.notice, "\(row.key) notice")
            #expect((content.tone == .warn) == (entry.tone == "warn"), "\(row.key) tone")
        }
    }

    /// The words lane: the fixture's fixed sentences verbatim, and the real transcript wherever the
    /// prototype shows its sample.
    @Test func wordsAreTheFixturesFixedSentencesOrTheRealText() throws {
        let fixture = try Self.fixture()
        let fixed = ["starting", "cancelled", "muted", "unavailable", "meeting", "paused", "notes", "blocked"]
        for row in Self.rendered() where fixed.contains(row.key) {
            let entry = try #require(fixture[row.key])
            let words = try #require(row.content.words.text, "\(row.key) has no words")
            #expect(entry.strings.count > 1 && entry.strings[1] == words, "\(row.key): \(words)")
        }
        let transcript = ["listening", "quiet", "latched", "finishing", "preview", "uncertain", "inserting", "inserted",
                          "held", "unconfirmed", "partial", "warning", "error"]
        for row in Self.rendered() where transcript.contains(row.key) {
            #expect(row.content.words.text == Self.sample, "\(row.key) must show the real text")
        }
    }

    /// The three substitutions, with a key and a destination that are not the prototype's.
    @Test func theConfiguredKeyAndTheRealDestinationReplaceThePrototypes() {
        var c = Self.prototypeContext()
        c.keyLabel = "fn / 🌐"
        c.destination = "Notes"
        #expect(PillContent.make(.listening(level: 0.3), context: c).helper == "Release fn / 🌐 to finish")
        #expect(PillContent.make(.latched(elapsed: 3), context: c).helper == "Tap fn / 🌐 to finish")
        let preview = FinalPreviewInfo(text: "hi", dwellRemaining: 0.9, destination: "Notes")
        #expect(PillContent.make(.finalPreview(preview), context: c).status == "Ready for Notes")
        #expect(PillContent.make(.inserting(text: "hi"), context: c).status == "Inserting in Notes…")
        #expect(PillContent.make(.landed(LandedPillInfo(text: "hi", verified: true)), context: c).status == "✓ Inserted in Notes")
        #expect(PillContent.make(.undoAvailable, context: c).status == "✓ Updated in Notes")
        let listening = PillContent.make(.listening(level: 0.3), context: c)
        #expect(listening.trailing == .timer(6))
        #expect(listening.trailing.text == "0:06")
        for row in Self.rendered() {
            #expect(!row.content.status.contains("fn / 🌐"))   // prototype context keeps its own key
        }
        for state: PillState in [.listening(level: 0.1), .latched(elapsed: 2)] {
            let content = PillContent.make(state, context: c)
            #expect(!content.helper.contains("Right Control"))
            #expect(!content.accessibilityLabel.contains("Mail"))
        }
    }

    /// I0 / I1 — the chin draws no text; the hint is the fixture's sentence with the configured key.
    @Test func theChinAndTheHintMatchTheFixture() throws {
        let fixture = try Self.fixture()
        let ready = try #require(fixture["ready"]?.text)
        #expect(PillState.readyHint(key: "Right Control") == ready)
        #expect(HotkeyBinding(kind: .rightControl).readyHint() == ready)
        #expect(HotkeyBinding.default.readyHint() == "Hold or Double Tap fn / 🌐 to dictate")
        let hint = PillContent.make(.ready(hint: ready), context: PillTurnContext())
        #expect(hint.status == ready)
        #expect(hint.isHint && !hint.showsSpool && hint.buttons.isEmpty)
        #expect(PillContent.make(.hidden, context: PillTurnContext()).isHidden)
        #expect(fixture["idle"]?.status == nil)
    }

    /// Strings the fixture does not carry come from the prototype's own sources: "Esc · cancel" from
    /// `pillHtml`, the finishing timeouts from design §5.
    @Test func copyOutsideTheFixtureIsTheDesignsOwn() throws {
        let dir = try #require(AppPaths.fixturesDirectory())
        let root = dir.deletingLastPathComponent()
        let html = try String(contentsOf: root.appendingPathComponent("design/design_v1.html"), encoding: .utf8)
        #expect(html.contains("'\(PillDeck.escapeHint)'"))
        #expect(html.contains("'\(PillDeck.listeningPlaceholder)'"))
        let md = try String(contentsOf: root.appendingPathComponent("design/design_v1.md"), encoding: .utf8)
        for phrase in [PillDeck.finishingSlowStatus, PillDeck.useAvailableText, "“\(PillDeck.cancelLabel)”"] {
            #expect(md.contains(phrase), "\(phrase)")
        }
        #expect(md.contains("after 10 s"))
        #expect(PillDeck.finishingOfferDelay == 10)
        #expect(PillState.finishingWarningDelay == 2)
    }

    /// Readback: any delivery readback did not confirm is the design's `unconfirmed` row (V4.20 withdrawn).
    @Test func anUnconfirmedDeliveryIsTheUnconfirmedRow() throws {
        let fixture = try Self.fixture()
        let state = PillDeliveryRouter.state(for: .delivered(verified: false, method: "paste"), text: "x", destination: "Docs")
        let content = PillContent.make(state, context: PillTurnContext(destination: "Docs"))
        #expect(content.designKey == "unconfirmed")
        #expect(content.status == fixture["unconfirmed"]?.status)
        #expect(!content.status.contains("✓"))
        #expect(PillDwell.staysUntilAction(state))
    }
}
