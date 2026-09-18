import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// S6 — what the menu's first line says, derived from the owners' state, and every menu string
/// against the verified design's fixtures.
@Suite("Menu status line and copy (S6)")
struct MenuStatusTests {
    static let packageRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }()

    static func json(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: packageRoot.appendingPathComponent(relativePath))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Derivation

    static func derive(_ engine: EngineState = .idle, muted: Bool = false, paused: Bool = false, canCapture: Bool = true,
                       canUseHotkey: Bool = true, holder: SessionCoordinator.Requester? = nil, latched: Bool = false,
                       meeting: Bool = false, presence: PresenceState? = nil) -> (MenuStatus, Bool) {
        let inputs = MenuStatusInputs(muted: muted, paused: paused, canCapture: canCapture, canUseHotkey: canUseHotkey,
                                      engine: engine, holder: holder, latched: latched, meetingRunning: meeting,
                                      presence: presence)
        return (MenuStatus.derive(inputs), inputs.dictationCaptureOpen)
    }

    /// Wave-0 handoff: `.starting` and `.finishing` used to read as "listening, level 0" — an open
    /// microphone that was not open yet, or already closed.
    @Test func startingAndFinishingAreNotListening() {
        let starting = Self.derive(.starting, holder: .hotkey)
        #expect(starting.0 == .starting && starting.1, "starting is stoppable, and not 'listening'")
        let finishing = Self.derive(.finishing)
        #expect(finishing.0 == .finishing && !finishing.1, "finishing has a closed microphone: no Stop")
        #expect(Self.derive(.finalizing).0 == .finishing)
        #expect(MenuStatus.starting.title != MenuStatus.listening.title)
        #expect(MenuStatus.finishing.detail.hasPrefix("Microphone closed"))
    }

    @Test func openMicrophoneStates() {
        #expect(Self.derive(.listening(level: 0.3), holder: .hotkey) == (.listening, true))
        #expect(Self.derive(.previewing(text: "hi"), holder: .menu) == (.listening, true))
        #expect(Self.derive(.warning(.unknownGood), holder: .hotkey) == (.listening, true))
        #expect(Self.derive(.listening(level: 0.3), latched: true) == (.latched, true))
        // Latch keeps the session open between segments.
        #expect(Self.derive(.idle, latched: true) == (.latched, true))
        #expect(Self.derive(.finishing, latched: true) == (.latched, true))
        // The menu asked, the engine has not answered yet: opening.
        #expect(Self.derive(.idle, holder: .menu) == (.starting, true))
        #expect(Self.derive(.landed, holder: .hotkey) == (.starting, true))
    }

    @Test func notCaptureStates() {
        // Warming the model is not opening the microphone.
        #expect(Self.derive(.prewarming) == (.ready, false))
        #expect(Self.derive(.idle) == (.ready, false))
        #expect(Self.derive(.cancelled) == (.ready, false))
        // A start that failed is not "opening" and offers Start again, not Stop.
        #expect(Self.derive(.error("boom"), holder: .menu) == (.ready, false))
        // Meeting capture holds the microphone for a meeting: named, but not dictation's Stop.
        #expect(Self.derive(.idle, holder: .meeting, meeting: true) == (.meeting, false))
        #expect(Self.derive(.idle, holder: .onboarding) == (.ready, false))
    }

    @Test func mutedOutranksEverything() {
        #expect(Self.derive(.listening(level: 1), muted: true, holder: .hotkey).0 == .muted)
        #expect(Self.derive(.idle, muted: true, canCapture: false).0 == .muted)
        #expect(Self.derive(.idle, presence: .muted).0 == .muted)
        #expect(Self.derive(.idle, muted: true, meeting: true).0 == .muted)
    }

    @Test func blockedReasons() {
        #expect(Self.derive(canCapture: false).0 == .blocked(.microphoneDenied))
        #expect(Self.derive(.unavailable("No speech model installed")).0 == .blocked(.modelMissing))
        #expect(Self.derive(presence: .blocked(.hotkeyUnavailable)).0 == .blocked(.hotkeyUnavailable))
        // Derived from the capabilities when the presence reducer is not wired; the microphone first.
        #expect(Self.derive(canUseHotkey: false).0 == .blocked(.hotkeyUnavailable))
        #expect(Self.derive(canCapture: false, canUseHotkey: false).0 == .blocked(.microphoneDenied))
        #expect(Self.derive(canUseHotkey: false, presence: .blocked(.relaunchNeeded)).0 == .blocked(.relaunchNeeded))
        #expect(Self.derive(presence: .blocked(.relaunchNeeded)).0 == .blocked(.relaunchNeeded))
        #expect(Self.derive(presence: .blocked(.modelDownloading(0.5))).0 == .blocked(.modelDownloading(0.5)))
        // An open microphone is said first; a blocker the key has does not hide it.
        #expect(Self.derive(.listening(level: 0.2), holder: .menu, presence: .blocked(.hotkeyUnavailable)).0 == .listening)
        #expect(Self.derive(paused: true).0 == .paused)
        #expect(Self.derive(presence: .ready).0 == .ready)
    }

    @Test func onlyMicrophoneModelMuteAndFinishingDisableStart() {
        let disabling: [MenuStatus] = [.muted, .finishing, .blocked(.microphoneDenied), .blocked(.modelMissing)]
        let enabled: [MenuStatus] = [.ready, .starting, .listening, .latched, .meeting, .paused,
                                     .blocked(.hotkeyUnavailable), .blocked(.relaunchNeeded),
                                     .blocked(.modelDownloading(0.1))]
        for status in disabling {
            #expect(status.disablesDictation && status.dictationBlockedReason != nil, "\(status)")
        }
        for status in enabled {
            #expect(!status.disablesDictation && status.dictationBlockedReason == nil, "\(status)")
        }
    }

    // MARK: Copy parity with the verified design

    /// The prototype's menu review surface (`case'menu'` in `design_v1.html`): every row's title and
    /// helper, verbatim, in order. The two §8.8-only rows (microphone, Settings…) are not drawn there.
    @Test func rowsAreThePrototypesMenuVerbatim() throws {
        let html = try String(contentsOf: Self.packageRoot.appendingPathComponent("design/design_v1.html"),
                              encoding: .utf8)
        let start = try #require(html.range(of: "case'menu':"))
        let end = try #require(html.range(of: "break;", range: start.upperBound..<html.endIndex))
        let block = String(html[start.upperBound..<end.lowerBound])
        let regex = try NSRegularExpression(pattern: #"row\('((?:[^'\\]|\\.)*)','((?:[^'\\]|\\.)*)'"#)
        let prototype: [[String]] = regex.matches(in: block, range: NSRange(block.startIndex..., in: block)).map { match in
            (1...2).map { group in
                let raw = String(block[Range(match.range(at: group), in: block)!])
                return raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            }
        }
        let state = StatusMenuState(held: [StatusMenuState.Held(id: UUID(), title: "“held” — Notes")])
        let ours = StatusMenuSpec.entries(state)
            .filter { !$0.isSeparator && $0.id != StatusMenuSpec.ID.microphone && $0.id != StatusMenuSpec.ID.settings }
            .map { [$0.title, $0.detail ?? ""] }
        #expect(prototype.count == 6)
        #expect(ours == prototype)
        // The screen's own title and subtitle come from the copy fixture.
        let copy = try Self.json("Fixtures/design/design_copy.json")
        let menu = try #require((copy["screens"] as? [String: Any])?["menu"] as? [String: String])
        #expect(block.contains(menu["title"] ?? "∅") && block.contains(menu["subtitle"] ?? "∅"))
    }

    /// The in-between states use the pill's own words (`design_copy.json` › `pill`).
    @Test func stateWordsAreThePills() throws {
        let copy = try Self.json("Fixtures/design/design_copy.json")
        let pill = try #require(copy["pill"] as? [String: [String: Any]])
        func status(_ key: String) -> String? { pill[key]?["status"] as? String }
        func strings(_ key: String) -> [String] { pill[key]?["strings"] as? [String] ?? [] }

        #expect(status("starting") == MenuCopy.Pill.starting)
        #expect(strings("starting").contains(MenuCopy.Pill.startingDetail))
        #expect(status("listening") == MenuCopy.Pill.listening)
        #expect(status("latched") == MenuCopy.Pill.latched)
        #expect(status("finishing") == MenuCopy.Pill.finishing)
        #expect(strings("finishing").contains(MenuCopy.Pill.finishingDetail))
        #expect(status("meeting") == MenuCopy.Pill.meeting)
        #expect(strings("meeting").contains(MenuCopy.Pill.meetingDetail))
    }

    /// Blocked and disabled reasons are recovery-catalogue lines, verbatim (`design_copy.json` ›
    /// `errors`), and the menu's screen error (`screenError.menu`) is the one it shows when muted.
    @Test func reasonsAreCatalogueLines() throws {
        let copy = try Self.json("Fixtures/design/design_copy.json")
        let errors = try #require(copy["errors"] as? [[String: String]])
        let byID = Dictionary(uniqueKeysWithValues: errors.compactMap { e in e["id"].map { ($0, e) } })
        for line in MenuCopy.Catalogue.all {
            let entry = try #require(byID[line.id], "no catalogue entry \(line.id)")
            #expect(entry["headline"] == line.headline, "\(line.id) headline")
            #expect(entry["consequence"] == line.consequence, "\(line.id) consequence")
            #expect(entry["action"] == line.action, "\(line.id) action")
        }
        let screenError = try #require(copy["screenError"] as? [String: String])
        #expect(screenError["menu"] == MenuCopy.Catalogue.muted.id)
        #expect(MenuStatus.muted.detail == byID["K05"]?["consequence"])
        #expect(MenuStatus.blocked(.microphoneDenied).detail
                == "\(byID["P01"]?["headline"] ?? "") — \(byID["P01"]?["action"] ?? "")")
        #expect(MenuStatus.blocked(.modelMissing).detail
                == "\(byID["M01"]?["headline"] ?? "") — \(byID["M01"]?["action"] ?? "")")
        #expect(MenuStatus.blocked(.hotkeyUnavailable).detail
                == "\(byID["P03"]?["headline"] ?? "") — \(byID["P03"]?["action"] ?? "")")
        // "Reopen VoicePlus to finish setup — Reopen VoicePlus" would say the action twice.
        #expect(MenuStatus.blocked(.relaunchNeeded).detail == byID["P04"]?["headline"])
        #expect(MenuStatus.muted.dictationBlockedReason == byID["K05"]?["headline"])
        #expect(MenuStatus.finishing.dictationBlockedReason?.lowercased() == byID["K04"]?["headline"]?.lowercased())
    }

    /// `DESIGN.md` §7.1: no raw enum tokens, no exclamation marks, no "please", no "Oops" — in any
    /// string any state of the menu or the quit guard can show.
    @Test func copyVoice() {
        let statuses: [MenuStatus] = [.ready, .starting, .listening, .latched, .finishing, .meeting, .muted, .paused,
                                      .blocked(.microphoneDenied), .blocked(.hotkeyUnavailable),
                                      .blocked(.relaunchNeeded), .blocked(.modelMissing),
                                      .blocked(.modelDownloading(0.3))]
        var strings: [String] = []
        for status in statuses {
            for capturing in [false, true] {
                let held = [StatusMenuState.Held(id: UUID(), title: "“a” — Notes")]
                strings += StatusMenuSpec.entries(StatusMenuState(status: status, isCapturing: capturing, held: held))
                    .flatMap { [$0.title, $0.detail ?? ""] }
            }
        }
        for plan in [MenuQuit.plan(dictating: true, meeting: true, held: [StatusMenuState.Held(id: UUID(), title: "“x” — Notes")]),
                     MenuQuit.plan(dictating: false, meeting: false, held: [StatusMenuState.Held(id: UUID(), title: "“y”")])] {
            if case .ask(let prompt) = plan { strings += [prompt.title, prompt.message, prompt.confirm, prompt.cancel] }
        }
        let camel = try? NSRegularExpression(pattern: #"\b[a-z]+[A-Z][A-Za-z]*\b"#)
        for string in strings where !string.isEmpty {
            #expect(!string.contains("!"), "\(string)")
            #expect(!string.lowercased().contains("please") && !string.lowercased().contains("oops"), "\(string)")
            let range = NSRange(string.startIndex..., in: string)
            #expect(camel?.firstMatch(in: string, range: range) == nil, "raw token in \(string)")
            #expect(!string.contains("Error") && !string.contains(".bin") && !string.contains(".partial"), "\(string)")
        }
    }

    // MARK: Quit

    @Test func quitPlans() {
        let saved = StatusMenuState.Held(id: UUID(), title: "“saved words” — Notes", text: "saved words", isSaved: true)
        let lost = StatusMenuState.Held(id: UUID(), title: "“lost words” — Mail", text: "lost words", isSaved: false)

        // Idle with nothing held, or with everything held already saved: just quit.
        #expect(MenuQuit.plan(dictating: false, meeting: false, held: []) == .quit)
        #expect(MenuQuit.plan(dictating: false, meeting: false, held: [saved]) == .quit)

        // Capture open: Stop and quit / Cancel, and the prompt says what stopping costs.
        guard case .ask(let capture) = MenuQuit.plan(dictating: true, meeting: false, held: [saved]) else {
            Issue.record("quitting during capture did not ask")
            return
        }
        #expect(capture.confirm == "Stop and quit" && capture.cancel == "Cancel" && capture.stopsCapture)
        #expect(capture.title == "Quit VoicePlus?")
        #expect(capture.message.contains(MenuQuit.dictationLine))
        #expect(capture.message.contains("1 held dictation is saved in Today."))

        guard case .ask(let meeting) = MenuQuit.plan(dictating: false, meeting: true, held: []) else {
            Issue.record("quitting during a meeting did not ask")
            return
        }
        #expect(meeting.stopsCapture && meeting.message == MenuQuit.meetingLine)

        // Nothing capturing, a draft that could not be saved: the unsaved-data warning names it.
        guard case .ask(let warning) = MenuQuit.plan(dictating: false, meeting: false, held: [saved, lost]) else {
            Issue.record("an unsaved draft did not warn")
            return
        }
        #expect(!warning.stopsCapture && warning.confirm == "Quit anyway" && warning.cancel == "Cancel")
        #expect(warning.message == "1 held dictation hasn’t been saved and will be lost: “lost words” — Mail.")

        let many = (0..<5).map { StatusMenuState.Held(id: UUID(), title: "“\($0)”") }
        guard case .ask(let manyWarning) = MenuQuit.plan(dictating: false, meeting: false, held: many) else {
            Issue.record("unsaved drafts did not warn")
            return
        }
        #expect(manyWarning.message == "5 held dictations haven’t been saved and will be lost: “0”; “1”; “2”; and 2 more.")
    }

    @Test func heldDraftsAreSavedToHistoryOnce() throws {
        let db = try AppDatabase.inMemory()
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        try db.insert(DictationRecord(startedAt: at, endedAt: at, register: "chat", route: "dictate", appBundleID: nil,
                                      rawText: "already there", finalText: "already there", spansJSON: "[]"))
        let held = [
            StatusMenuState.Held(id: UUID(), title: "“already there”", text: "already there ", heldAt: at),
            StatusMenuState.Held(id: UUID(), title: "“new words” — Notes", text: "new words", heldAt: at),
            StatusMenuState.Held(id: UUID(), title: "“new words” — Notes", text: "new words", heldAt: at),
            StatusMenuState.Held(id: UUID(), title: "“”", text: "  "),
        ]
        let saved = HeldDrafts.save(held, into: db)
        #expect(saved.map(\.isSaved) == [true, true, true, false])
        let texts = try db.recentDictations(limit: 50).map(\.finalText)
        #expect(texts.filter { $0 == "already there" }.count == 1, "an already-saved draft was written again")
        #expect(texts.filter { $0 == "new words" }.count == 1, "a draft was written twice")
        // Saving again changes nothing.
        _ = HeldDrafts.save(held, into: db)
        #expect(try db.recentDictations(limit: 50).count == 2)
        // No database: nothing can be saved, and nothing claims it was.
        #expect(HeldDrafts.save(held, into: nil).allSatisfy { !$0.isSaved })
        #expect(HeldDrafts.save([], into: db).isEmpty)
    }
}
