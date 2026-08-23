import Foundation
import Testing
@testable import Actions

@Suite("P4.4 consent engine")
struct ConsentTests {
    final class Box: @unchecked Sendable { var ran: [String] = []; var undone: [String] = []; let l = NSLock()
        func add(_ s: String) { l.lock(); ran.append(s); l.unlock() } }

    func engine(_ box: Box, now: @escaping @Sendable () -> TimeInterval = { 0 }) -> ConsentEngine {
        let reg = CompensatingActionRegistry()
        reg.register("slack.send_message") { _, receipt in box.l.lock(); box.undone.append(receipt.handle); box.l.unlock() }
        return ConsentEngine(registry: reg, now: now)
    }

    @Test func policyTable() {
        let c = ActionClassifier()
        for (id, cls) in ActionClassifier.idRules { #expect(c.classify(ConsentRequest(id: id)) == cls) }
        for (cat, cls) in ActionClassifier.categoryRules { #expect(c.classify(ConsentRequest(id: "x.y", category: cat)) == cls) }
        #expect(c.classify(ConsentRequest(id: "ax.anything_new")) == .reversible)
        #expect(c.classify(ConsentRequest(id: "payment.refund")) == .irreversible)
        #expect(c.classify(ConsentRequest(id: "unknown.thing")) == .irreversible)             // conservative default
        #expect(c.classify(ConsentRequest(id: "slack.send_message", flags: ["external_recipient"])) == .irreversible)
        #expect(c.classify(ConsentRequest(id: "ax.click", flags: ["bulk"])) == .semi)
        #expect(c.classify(ConsentRequest(id: "ax.click", flags: ["destructive"])) == .irreversible)
        #expect(c.classify(ConsentRequest(id: "fs.delete", flags: ["bulk"])) == .irreversible)  // never de-escalates
    }

    @Test func reversibleJustRuns() async throws {
        let b = Box(); let e = engine(b)
        let (_, out) = try await e.submit(ConsentRequest(id: "ax.click")) { r in b.add(r.id); return ExecutionReceipt() }
        #expect(out == .executed(ExecutionReceipt())); #expect(b.ran == ["ax.click"])
    }

    @Test func semiRunsThenUndoWithinWindow() async throws {
        let b = Box(); let clock = ClockBox(); let e = engine(b) { clock.t }
        let (tok, out) = try await e.submit(ConsentRequest(id: "slack.send_message")) { _ in b.add("send"); return ExecutionReceipt(handle: "ts123") }
        guard case .executedWithUndo(let toast, _) = out else { Issue.record("expected toast"); return }
        #expect(b.ran == ["send"]); #expect(toast.ring(at: 0) == 1); #expect(toast.ring(at: 2.5) == 0.5); #expect(toast.ring(at: 9) == 0)
        clock.t = 4.9
        #expect(try await e.undo(tok)); #expect(b.undone == ["ts123"])
        #expect(try await e.undo(tok) == false)                                             // already undone
    }

    @Test func undoExpiresAfterFiveSeconds() async throws {
        let b = Box(); let clock = ClockBox(); let e = engine(b) { clock.t }
        let (tok, _) = try await e.submit(ConsentRequest(id: "slack.send_message")) { _ in ExecutionReceipt(handle: "x") }
        clock.t = 5.01; e.expireToasts()
        #expect(try await e.undo(tok) == false); #expect(b.undone.isEmpty); #expect(e.toast(tok)?.expired == true)
    }

    @Test func semiWithoutCompensatorCannotUndo() async throws {
        let b = Box(); let e = engine(b)
        let (tok, _) = try await e.submit(ConsentRequest(id: "git.commit")) { _ in ExecutionReceipt() }
        #expect(try await e.undo(tok) == false)
    }

    @Test func irreversibleWaitsForConfirmOrClick() async throws {
        let b = Box(); let e = engine(b)
        let (tok, out) = try await e.submit(ConsentRequest(id: "fs.delete")) { r in b.add(r.id); return ExecutionReceipt() }
        guard case .awaitingConfirmation = out else { Issue.record("expected card"); return }
        #expect(b.ran.isEmpty)
        _ = try await e.confirm(tok, spoken: "confirm the meeting")                          // not the grammar
        #expect(b.ran.isEmpty); #expect(e.pendingCard(tok) != nil)
        #expect(try await e.confirm(tok, spoken: "Confirm.") == .executed(ExecutionReceipt()))
        #expect(b.ran == ["fs.delete"])
        #expect(try await e.confirm(tok) == .cancelled)                                      // one-shot
        // click path + spoken cancel
        let (t2, _) = try await e.submit(ConsentRequest(id: "payment.pay")) { r in b.add(r.id); return ExecutionReceipt() }
        #expect(try await e.confirm(t2) == .executed(ExecutionReceipt()))
        let (t3, _) = try await e.submit(ConsentRequest(id: "shell.run")) { r in b.add(r.id); return ExecutionReceipt() }
        #expect(try await e.confirm(t3, spoken: "cancel") == .cancelled); #expect(e.pendingCard(t3) == nil)
        #expect(b.ran == ["fs.delete", "payment.pay"])
    }

    /// Fuzz: random ids/categories/flags; an action classified irreversible must never run unconfirmed,
    /// and unknown ids must never run at all without confirmation.
    @Test func fuzzIrreversibleNeverExecutesUnconfirmed() async throws {
        var rng = SystemRandomNumberGenerator()
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz._")
        let knownIDs = Array(ActionClassifier.idRules.keys)
        let c = ActionClassifier()
        for _ in 0..<2000 {
            let id: String = Bool.random(using: &rng) ? knownIDs.randomElement(using: &rng)!
                : String((0..<Int.random(in: 1...20, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
            let cat = ConsentCategory.allCases.randomElement(using: &rng)!
            let flags = Set(ActionClassifier.escalations.keys.filter { _ in Bool.random(using: &rng) })
            let r = ConsentRequest(id: id, category: cat, flags: flags)
            let b = Box(); let e = engine(b)
            let (_, out) = try await e.submit(r) { (x: ConsentRequest) in b.add(x.id); return ExecutionReceipt() }
            let cls = c.classify(r)
            if cls == .irreversible {
                #expect(b.ran.isEmpty, "irreversible \(r) executed unconfirmed")
                guard case .awaitingConfirmation = out else { Issue.record("no card for \(r)"); continue }
            } else {
                #expect(b.ran == [id])
            }
            if ActionClassifier.idRules[id] == nil, !id.hasPrefix("ax."), !id.hasPrefix("text."), !id.hasPrefix("nav."),
               ActionClassifier.categoryRules[cat] == nil {
                #expect(cls == .irreversible, "unknown id \(id) must default conservative")
            }
            if flags.contains("destructive") || flags.contains("external_recipient") { #expect(cls == .irreversible) }
        }
    }

    final class ClockBox: @unchecked Sendable { var t: TimeInterval = 0 }
}

@Suite("P4.4 deterministic bridge")
struct ConsentBridgeTests {
    @Test func catalogRequestsClassify() {
        let c = ActionClassifier()
        #expect(c.classify(ConsentRequest(ActionRequest(kind: .click))) == .reversible)
        #expect(c.classify(ConsentRequest(ActionRequest(kind: .shortcut, reversibility: .semi))) == .semi)
        #expect(c.classify(ConsentRequest(ActionRequest(kind: .click, reversibility: .irreversible, catalogID: "ax.click"))) == .irreversible)
    }
}
