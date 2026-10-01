import Engine
import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// V5 N2 — the live routes into Notes beyond the wake verb: no focused field, latch during a meeting
/// and an agent action running (decided at landing, hold and latch alike), an app switch mid-segment
/// and K4 "another voice" (inside the latch runtime). Real lander + latch runtime over
/// `MockSystemAccess`; a real `NotesStore` on a temp folder.
@Suite("V5 N2 live routes into Notes")
@MainActor
struct NotesLiveRoutesTests {
    typealias Stack = LatchLanderPathTests.Stack

    final class Flags: @unchecked Sendable {
        var latched = false
        var meeting = false
        var agent = false
    }

    struct Notes {
        let root: URL
        let store: NotesStore
        let router: NotesRouter
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("n2-\(UUID().uuidString)", isDirectory: true)
            store = NotesStore(root: root, database: try AppDatabase.inMemory())
            router = NotesRouter(store: store)
        }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
        var entries: [NoteEntry] { store.notes() }
    }

    private func wire(_ stack: Stack, _ notes: Notes, _ flags: Flags) {
        stack.lander.notesClaim = NotesWiring.landingClaim(notes.router, latched: { flags.latched },
                                                           meetingActive: { flags.meeting },
                                                           agentRunning: { flags.agent })
        stack.runtime.notesRoute = NotesWiring.latchRoute(notes.router, meetingActive: { flags.meeting })
    }

    private func hold(_ stack: Stack, _ text: String) async -> LandingResult {
        await stack.lander.land(LatchLanderPathTests.spans([text]), startedAt: Date(), focus: stack.system.frontmost)
    }

    @Test("a field is focused, nothing special: the hold types as before")
    func plainDictationTypes() async throws {
        let notes = try Notes(); defer { notes.cleanUp() }
        let stack = Stack(), flags = Flags()
        wire(stack, notes, flags)
        let result = await hold(stack, "meet me at noon")
        #expect(result.noted == nil)
        #expect(stack.requests.count == 1)
        #expect(notes.entries.isEmpty)
    }

    @Test("no focused field: the words go to Notes (no-field), nothing is typed")
    func noFocusedField() async throws {
        let notes = try Notes(); defer { notes.cleanUp() }
        let stack = Stack(), flags = Flags()
        stack.system.hasFocusedElement = false
        wire(stack, notes, flags)
        let result = await hold(stack, "buy milk on the way home")
        #expect(result.noted == .noField)
        #expect(result.injection == nil)
        #expect(stack.requests.isEmpty)
        #expect(notes.entries.map(\.source) == [.noField])
        #expect(notes.entries.first?.text.lowercased().contains("buy milk") == true)
        // O3: logged as a note, not 'ignore'.
        #expect(UtteranceDecisionHub.decision(for: result).owner == .note)
    }

    @Test("latch during a meeting: a meeting aside, even with a field focused")
    func latchInMeeting() async throws {
        let notes = try Notes(); defer { notes.cleanUp() }
        let stack = Stack(), flags = Flags()
        flags.latched = true
        flags.meeting = true
        wire(stack, notes, flags)
        stack.runtime.handle(LatchLanderPathTests.closed(0, LatchLanderPathTests.spans(["remind me to send the deck"])))
        await stack.runtime.settle()
        #expect(stack.requests.isEmpty)
        #expect(notes.entries.map(\.source) == [.meetingAside])
        #expect(stack.runtime.outcomes.first?.outcome == .consumed)
    }

    @Test("a hold during a meeting still types (only latch is an aside)")
    func holdInMeetingTypes() async throws {
        let notes = try Notes(); defer { notes.cleanUp() }
        let stack = Stack(), flags = Flags()
        flags.meeting = true
        wire(stack, notes, flags)
        let result = await hold(stack, "the numbers look good")
        #expect(result.noted == nil)
        #expect(stack.requests.count == 1)
    }

    @Test("an agent action running: the utterance is noted, never typed under the agent")
    func agentRunning() async throws {
        let notes = try Notes(); defer { notes.cleanUp() }
        let stack = Stack(), flags = Flags()
        flags.agent = true
        wire(stack, notes, flags)
        let result = await hold(stack, "also check the invoices")
        #expect(result.noted == .agentRunning)
        #expect(stack.requests.isEmpty)
        #expect(notes.entries.map(\.source) == [.agentRunning])
    }

    @Test("a password field is never a note")
    func secureFieldNeverNoted() async throws {
        let notes = try Notes(); defer { notes.cleanUp() }
        let stack = Stack(field: .secure()), flags = Flags()
        flags.agent = true
        wire(stack, notes, flags)
        let result = await hold(stack, "hunter two")
        #expect(result.noted == nil)
        #expect(result.injection == .refused(.secureField))
        #expect(notes.entries.isEmpty)
    }

    @Test("app switch mid-segment: Notes keeps it (app-switch), neither app gets it, nothing held")
    func appSwitchMidSegment() async throws {
        let notes = try Notes(); defer { notes.cleanUp() }
        let stack = Stack(), flags = Flags()
        wire(stack, notes, flags)
        stack.runtime.handle(.opened(SegmentID(sessionID: LatchLanderPathTests.session, index: 0)))
        stack.runtime.noteVAD(.speechStart(at: 0.2))
        stack.system.frontmost = LatchLanderPathTests.mail
        stack.runtime.handle(LatchLanderPathTests.closed(0, LatchLanderPathTests.spans(["meet me at three thirty"])))
        await stack.runtime.settle()
        #expect(stack.requests.isEmpty)
        #expect(stack.focusGuard.held.isEmpty)
        #expect(notes.entries.map(\.source) == [.appSwitch])
        #expect(stack.runtime.outcomes.first?.outcome == .consumed)
    }

    @Test("without the notes route an app switch still holds for the first app (D01 unchanged)")
    func appSwitchWithoutRouteHolds() async {
        let stack = Stack()
        stack.runtime.handle(.opened(SegmentID(sessionID: LatchLanderPathTests.session, index: 0)))
        stack.runtime.noteVAD(.speechStart(at: 0.2))
        stack.system.frontmost = LatchLanderPathTests.mail
        stack.runtime.handle(LatchLanderPathTests.closed(0, LatchLanderPathTests.spans(["meet me at three"])))
        await stack.runtime.settle()
        #expect(stack.focusGuard.held.count == 1)
    }

    @Test("K4: latched speech in another voice is suppressed and kept in Notes as someone else's")
    func otherVoiceToNotes() async throws {
        let notes = try Notes(); defer { notes.cleanUp() }
        let stack = Stack(), flags = Flags()
        wire(stack, notes, flags)
        var noted: [NoteSource] = []
        notes.router.onNoted = { source, _ in noted.append(source) }
        stack.runtime.speakerGuard = { .suppress(.mismatch) }
        stack.runtime.handle(LatchLanderPathTests.closed(0, LatchLanderPathTests.spans(["can you pass the salt"])))
        await stack.runtime.settle()
        #expect(stack.requests.isEmpty)
        #expect(stack.runtime.outcomes.first?.outcome == .suppressed(.mismatch))
        #expect(notes.entries.map(\.source) == [.latch])
        #expect(notes.entries.first?.speaker != .you)
        #expect(noted == [.latch])
    }

    @Test("K4 in a meeting is a meeting aside; an uncertain verdict stores nothing")
    func otherVoiceInMeetingAndUncertain() async throws {
        let notes = try Notes(); defer { notes.cleanUp() }
        let stack = Stack(), flags = Flags()
        flags.meeting = true
        wire(stack, notes, flags)
        stack.runtime.speakerGuard = { .suppress(.mismatch) }
        stack.runtime.handle(LatchLanderPathTests.closed(0, LatchLanderPathTests.spans(["next slide please"])))
        await stack.runtime.settle()
        #expect(notes.entries.map(\.source) == [.meetingAside])

        stack.runtime.speakerGuard = { .suppress(.uncertain) }
        stack.runtime.handle(LatchLanderPathTests.closed(1, LatchLanderPathTests.spans(["maybe not me"])))
        await stack.runtime.settle()
        #expect(notes.entries.count == 1)
    }
}
