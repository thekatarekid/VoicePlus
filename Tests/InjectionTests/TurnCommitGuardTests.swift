import Foundation
import Shared
import Testing
@testable import Injection

/// S3 — the idempotent commit guard (`TurnID` + target revision), the partial classification, and
/// `FocusGuard`'s end-of-dwell revalidation.
@Suite("Turn commit guard and revalidation (S3)")
struct TurnCommitGuardTests {
    static let textEdit = FocusSnapshot(pid: 100, bundleID: "com.apple.TextEdit", appName: "TextEdit", elementToken: "el-1")
    static let mail = FocusSnapshot(pid: 200, bundleID: "com.apple.mail", appName: "Mail", elementToken: "el-2")

    static func stack(value: String = "") -> (TextInjector, MockSystemAccess) {
        let mock = MockSystemAccess(frontmost: textEdit)
        mock.field = MockSystemAccess.Field(role: "AXTextArea", value: value)
        return (TextInjector(system: mock), mock)
    }

    // MARK: The guard

    @Test("a second commit for the same turn and revision posts nothing")
    func secondCommitRefused() {
        let (injector, mock) = Self.stack()
        let key = TurnCommitKey(turnID: TurnID(), revision: 7)
        let request = InjectionRequest(text: "hello there", expectedFocus: mock.frontmost)

        let first = injector.commit(request, key: key)
        let posts = mock.postCount
        let second = injector.commit(request, key: key)

        #expect(first.report?.outcome.succeeded == true)
        #expect(!first.isDuplicate)
        #expect(second.isDuplicate)
        #expect(second.report == first.report, "the duplicate answers with the first commit's report")
        #expect(mock.postCount == posts, "the duplicate posted \(mock.postCount - posts) time(s)")
        #expect(mock.field.value == "hello there", "the text is in the field exactly once")
        #expect(injector.turnCommits.hasCommitted(key))
    }

    @Test("a new revision of the same turn (an explicit re-target) and another turn both commit")
    func otherKeysCommit() {
        let (injector, mock) = Self.stack()
        let turn = TurnID()
        let request = InjectionRequest(text: "a", expectedFocus: mock.frontmost)
        #expect(!injector.commit(request, key: TurnCommitKey(turnID: turn, revision: 1)).isDuplicate)
        #expect(!injector.commit(request, key: TurnCommitKey(turnID: turn, revision: 2)).isDuplicate)
        #expect(!injector.commit(request, key: TurnCommitKey(turnID: TurnID(), revision: 1)).isDuplicate)
        #expect(mock.field.value == "aaa")
    }

    @Test("a commit racing one still in flight is refused before anything posts")
    func inFlightDuplicate() {
        let guardian = TurnCommitGuard()
        let key = TurnCommitKey(turnID: TurnID(), revision: 0)
        var nested: TurnCommitResult?
        var deliveries = 0
        let outer = guardian.commit(key) {
            deliveries += 1
            // A duplicate callback arriving while the first write is still under way.
            nested = guardian.commit(key) {
                deliveries += 1
                return TurnCommitReport(.failed(attempts: []))
            }
            return TurnCommitReport(.injected(method: .ax, verified: true))
        }
        #expect(deliveries == 1)
        #expect(nested == .duplicate(key, previous: nil))
        #expect(outer == .committed(TurnCommitReport(.injected(method: .ax, verified: true))))
        #expect(guardian.commit(key) { TurnCommitReport(.failed(attempts: [])) }
                == .duplicate(key, previous: TurnCommitReport(.injected(method: .ax, verified: true))))
    }

    @Test("the guard's memory is bounded")
    func boundedMemory() {
        let guardian = TurnCommitGuard()
        guardian.memory = 2
        let keys = (0..<3).map { TurnCommitKey(turnID: TurnID(), revision: $0) }
        for key in keys { _ = guardian.commit(key) { TurnCommitReport(.failed(attempts: [])) } }
        #expect(!guardian.hasCommitted(keys[0]))
        #expect(guardian.hasCommitted(keys[1]) && guardian.hasCommitted(keys[2]))
    }

    @Test("focus moved before anything posted: the held copy carries the turn")
    func heldCopyCarriesTheTurn() {
        let (injector, mock) = Self.stack()
        let turn = TurnID()
        let request = InjectionRequest(text: "for textedit", expectedFocus: Self.textEdit)
        mock.frontmost = Self.mail
        let result = injector.commit(request, key: TurnCommitKey(turnID: turn, revision: 0))
        #expect(result.report?.outcome == .abortedFocusChanged(expected: Self.textEdit, actual: Self.mail))
        #expect(injector.focusGuard.heldText(turn: turn)?.text == "for textedit")
        #expect(mock.postCount == 0)
    }

    // MARK: Partial

    /// An AX write that puts half the text in and then throws.
    final class HalfWriter: MockSystemAccess {
        override func setFocusedSelectedText(_ text: String) throws {
            try super.setFocusedSelectedText(String(text.prefix(text.count / 2)))
            throw SystemAccessError.axError(-25200)
        }
    }

    @Test("a method that posted and then threw, unconfirmed, is partial — never 'nothing typed'")
    func postedThenThrewIsPartial() {
        let mock = HalfWriter(frontmost: Self.textEdit)
        mock.field = MockSystemAccess.Field(role: "AXTextArea", value: "")
        let injector = TextInjector(system: mock)
        let result = injector.commit(InjectionRequest(text: "hello world", expectedFocus: Self.textEdit),
                                     key: TurnCommitKey(turnID: TurnID(), revision: 0))
        let report = try? #require(result.report)
        #expect(report?.postedThenThrew == true)
        #expect(report?.delivery == .partial(method: "ax"))
        #expect(mock.postCount == 1, "no second method after a post (readback rule)")
    }

    @Test("a clean unconfirmed post stays unconfirmed, not partial")
    func unconfirmedIsNotPartial() {
        let report = TurnCommitReport(.injected(method: .keystroke, verified: false))
        #expect(report.delivery == .delivered(verified: false, method: "keystroke"))
    }

    // MARK: Revalidation

    @Test("unchanged destination revalidates")
    func unchanged() {
        let (injector, _) = Self.stack(value: "Dear Mira, ")
        let guardian = injector.focusGuard
        let before = guardian.targetRevision()
        #expect(before.textVersion == TargetRevision.version(of: "Dear Mira, "))
        #expect(before.selection == 11..<11)
        #expect(before.elementHash != nil)
        #expect(guardian.revalidate(before) == .unchanged)
    }

    @Test("text, selection, focus and secure-field changes each hold")
    func changesHold() {
        let (injector, mock) = Self.stack(value: "abc")
        let guardian = injector.focusGuard
        let snapshot = guardian.targetRevision()

        mock.field.value = "abcd"
        #expect(guardian.revalidate(snapshot) == .textChanged)
        mock.field.value = "abc"
        mock.field.selection = 1..<1
        #expect(guardian.revalidate(snapshot) == .selectionChanged)
        mock.field.selection = 3..<3
        #expect(guardian.revalidate(snapshot) == .unchanged)
        mock.frontmost = Self.mail
        #expect(guardian.revalidate(snapshot) == .focusChanged)
        mock.frontmost = Self.textEdit
        mock.field = .secure()
        #expect(guardian.revalidate(snapshot) == .secureField)
    }

    @Test("our own landing since the snapshot covers a changed text version")
    func ownLandingCovers() {
        let (injector, mock) = Self.stack(value: "first segment.")
        let snapshot = injector.focusGuard.targetRevision()
        mock.field.value = "first segment. Second"
        mock.field.selection = 21..<21
        #expect(injector.focusGuard.revalidate(snapshot) == .textChanged)
        #expect(injector.focusGuard.revalidate(snapshot, ownLandingSinceSnapshot: true) == .unchanged)
        // …but never another app, and never a password field.
        mock.frontmost = Self.mail
        #expect(injector.focusGuard.revalidate(snapshot, ownLandingSinceSnapshot: true) == .focusChanged)
    }

    @Test("a value AX never exposed is not held against the target")
    func unreadableValueNotCompared() {
        let (injector, mock) = Self.stack(value: "x")
        mock.axReadable = false
        let snapshot = injector.focusGuard.targetRevision()
        #expect(snapshot.textVersion == nil)
        mock.field.value = "changed"
        #expect(injector.focusGuard.revalidate(snapshot) == .unchanged)
    }

    @Test("a password field's value is never hashed into the snapshot")
    func secureNotHashed() {
        let (injector, mock) = Self.stack()
        mock.field = .secure(webStyle: true)
        mock.field.value = "hunter2"
        let snapshot = injector.focusGuard.targetRevision()
        #expect(snapshot.isSecure)
        #expect(snapshot.textVersion == nil)
    }

    @Test("the version is stable FNV-1a")
    func stableVersion() {
        #expect(TargetRevision.version(of: "") == Int(bitPattern: UInt(0xcbf2_9ce4_8422_2325)))
        #expect(TargetRevision.version(of: "a") == TargetRevision.version(of: "a"))
        #expect(TargetRevision.version(of: "a") != TargetRevision.version(of: "b"))
    }

    // MARK: Held text resolution

    @Test("copy, discard and insert-here report their resolution with the turn")
    func resolutions() {
        let (injector, mock) = Self.stack()
        let guardian = injector.focusGuard
        var seen: [(TurnID?, HeldResolution)] = []
        guardian.onResolved = { item, how in seen.append((item.turnID, how)) }
        let t1 = TurnID(), t2 = TurnID(), t3 = TurnID()
        let a = guardian.hold(InjectionRequest(text: "a"), reason: DeliveryReason.destinationChanged, turnID: t1)
        let b = guardian.hold(InjectionRequest(text: "b"), reason: DeliveryReason.destinationChanged, turnID: t2)
        let c = guardian.hold(InjectionRequest(text: "c"), reason: DeliveryReason.destinationChanged, turnID: t3)
        guardian.copy(a.id)
        guardian.discard(b.id)
        let outcome = guardian.insertHere(c.id)
        #expect(outcome?.succeeded == true)
        #expect(mock.field.value == "c")
        #expect(seen.map(\.0) == [t1, t2, t3])
        #expect(seen.map(\.1) == [.copied, .discarded, .inserted(.injected(method: .ax, verified: true))])
    }

    @Test("insert-here that is held again keeps the turn on the new item")
    func reHeldKeepsTurn() {
        let (injector, mock) = Self.stack()
        let guardian = injector.focusGuard
        let turn = TurnID()
        let item = guardian.hold(InjectionRequest(text: "x", expectedFocus: Self.textEdit),
                                 reason: DeliveryReason.destinationChanged, turnID: turn)
        // "Insert here" into an app on the never-inject list: refused, and held again.
        injector.policy = StaticInjectionPolicy(neverInject: [Self.textEdit.bundleID])
        let outcome = guardian.insertHere(item.id)
        #expect(outcome == .refused(.neverInject))
        #expect(mock.postCount == 0)
        let again = guardian.heldText(turn: turn)
        #expect(again != nil && again?.id != item.id, "a new held item, for the same turn")
    }
}
