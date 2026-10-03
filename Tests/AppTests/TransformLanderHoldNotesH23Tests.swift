import Foundation
import GRDB
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// H23 (lander side) — `UtteranceLander.hold`: every former hold goes to Notes (through
/// `FocusGuard`'s Notes sink, with the intended app and the real reason, so the pill says "Saved to
/// Notes · <why>"); a password-field reason keeps nothing anywhere — not Notes, not the held list,
/// not history — and the result keeps no words. Mock AX field, in-memory database.
@Suite("H23 — lander holds go to Notes; password keeps nothing")
struct TransformLanderHoldNotesH23Tests {
    final class Sink { var items: [HeldText] = [] }

    struct Rig {
        let lander: UtteranceLander
        let guardian: FocusGuard
        let sink: Sink
        let system: MockSystemAccess
        let db: AppDatabase
    }

    static func rig(notes: Bool = true) throws -> Rig {
        let system = MockSystemAccess()
        system.field = .init(value: "hello ", selection: 6..<6)
        let db = try AppDatabase.inMemory()
        let lander = UtteranceLander(pipeline: PipelineRunner.standard(), injector: TextInjector(system: system), system: system,
                                     repair: nil, flags: .inMemory(), database: db)
        let guardian = FocusGuard(system: system)
        let sink = Sink()
        if notes { guardian.notesSink = { sink.items.append($0); return true } }
        return Rig(lander: lander, guardian: guardian, sink: sink, system: system, db: db)
    }

    static func payload(_ r: Rig, _ text: String) async -> LandingResult {
        await r.lander.land(TransformLandingTests.spans(text), startedAt: Date(), focus: r.system.frontmost, inject: false)
    }

    static func historyCount(_ r: Rig) throws -> Int { try r.db.reader.read { try DictationRecord.fetchCount($0) } }

    @Test("a hold goes to Notes with the intended app and the real reason; nothing typed, nothing held")
    func holdToNotes() async throws {
        let r = try Self.rig()
        let p = await Self.payload(r, "see you at five")
        #expect(p.isAwaitingInsertion)
        let out = r.lander.hold(payload: p, reason: DeliveryReason.noDestination, in: r.guardian, actual: nil, turnID: TurnID())
        #expect(r.sink.items.count == 1 && r.sink.items.first?.reason == DeliveryReason.noDestination)
        #expect(r.sink.items.first?.text.lowercased().contains("see you at five") == true)
        #expect(r.guardian.held.isEmpty, "no held queue")
        #expect(out.delivery == .held(reason: DeliveryReason.noDestination), "the real reason, so Notes says why")
        #expect(r.system.field.value == "hello ", "nothing typed")
        #expect(try Self.historyCount(r) == 1, "history keeps the words")
    }

    @Test("every hold reason (pull-back, kept by user, interrupted, changed) goes to Notes, carrying its reason")
    func everyReason() async throws {
        for reason in [DeliveryReason.keptByUser, DeliveryReason.destinationChanged, "window was closed", "screen locked"] {
            let r = try Self.rig()
            let p = await Self.payload(r, "words for later")
            let out = r.lander.hold(payload: p, reason: reason, in: r.guardian, actual: nil, turnID: nil)
            #expect(r.sink.items.map(\.reason) == [reason])
            #expect(r.guardian.held.isEmpty)
            #expect(out.delivery == .held(reason: reason))
        }
    }

    @Test("a password-field reason: nothing to Notes, the held list or history; the result keeps no words")
    func secureKeepsNothing() async throws {
        for reason in [DeliveryReason.secureField, DeliveryLadder.Reason.passwordField.rawValue] {
            let r = try Self.rig()
            let p = await Self.payload(r, "hunter two")
            let out = r.lander.hold(payload: p, reason: reason, in: r.guardian, actual: nil, turnID: TurnID())
            #expect(r.sink.items.isEmpty && r.guardian.held.isEmpty)
            #expect(try Self.historyCount(r) == 0)
            #expect(out.text.isEmpty && out.pending == nil)
            #expect(out.injection == .refused(.secureField))
            #expect(r.system.field.value == "hello ")
        }
    }

    @Test("a failed Notes save keeps the words with Copy (legacy held row) and in history")
    func failedSave() async throws {
        let r = try Self.rig(notes: false)
        r.guardian.notesSink = { _ in false }
        let p = await Self.payload(r, "keep me")
        _ = r.lander.hold(payload: p, reason: DeliveryReason.destinationChanged, in: r.guardian, actual: nil, turnID: nil)
        #expect(r.guardian.held.count == 1)
        #expect(try Self.historyCount(r) == 1)
    }
}
