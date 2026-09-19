import AppKit
import Foundation
import Shared
import Testing
@testable import Injection

/// FX1 — the onboarding "Try your first sentence" freeze. A turn's write into VoicePlus's own
/// practice field went through `AXUIElementSetAttributeValue` from a background thread; macOS runs an
/// AX request aimed at ourselves in-process on the calling thread, so AppKit edited the text view
/// off the main thread and TextKit 2 deadlocked against the main thread's layout.
///
/// These pin the routing: a write whose destination is our own process runs on the main thread,
/// through the in-process path, and never through an AX setter. The spy records the thread of every
/// call; nothing here posts a real event or touches a real app.
@Suite("FX1 — own-process writes never go through AX off the main thread")
struct OwnProcessRoutingTests {
    static let own = FocusSnapshot(pid: OwnProcess.pid, bundleID: "in.adityakatare.voiceplus", appName: "VoicePlus", elementToken: "own")
    static let textEdit = FocusSnapshot(pid: 100, bundleID: "com.apple.TextEdit", appName: "TextEdit", elementToken: "el-1")

    /// A `SystemAccess` that is also our own in-process text path, with a thread log.
    final class Spy: SystemAccess, InProcessTextDelivering, @unchecked Sendable {
        struct Call: Equatable {
            var name: String
            var onMain: Bool
        }
        private let lock = NSLock()
        private var _calls: [Call] = []
        private var _value: String
        private var _selection: Range<Int>
        private var _postCount = 0
        var frontmost: FocusSnapshot?
        var role = "AXTextArea"
        /// Our first responder is editable text (false: a button has focus).
        var hasTextResponder = true

        init(frontmost: FocusSnapshot?, value: String = "Hello ") {
            self.frontmost = frontmost
            _value = value
            _selection = value.utf16.count..<value.utf16.count
        }

        var calls: [Call] { lock.withLock { _calls } }
        var value: String { lock.withLock { _value } }
        func names(_ name: String) -> [Call] { calls.filter { $0.name == name } }
        /// The setters that would have run AppKit's AX handler on the calling thread.
        var axWrites: [Call] { calls.filter { $0.name.hasPrefix("ax.set") } }

        private func log(_ name: String) { lock.withLock { _calls.append(Call(name: name, onMain: Thread.isMainThread)) } }

        private var info: FocusedElementInfo {
            lock.withLock {
                FocusedElementInfo(role: role, value: _value, selectedRange: _selection, isValueSettable: true,
                                   isSelectedTextSettable: true, selectedText: "")
            }
        }

        private func insert(_ text: String) {
            lock.withLock {
                var units = Array(_value.utf16)
                units.replaceSubrange(_selection, with: Array(text.utf16))
                _value = String(decoding: units, as: UTF16.self)
                let caret = _selection.lowerBound + text.utf16.count
                _selection = caret..<caret
                _postCount += 1
            }
        }

        // SystemAccess
        var isAccessibilityTrusted: Bool { true }
        var postCount: Int { lock.withLock { _postCount } }
        func frontmostApp() -> FocusSnapshot? { log("frontmostApp"); return frontmost }
        func focusedElement() throws -> FocusedElementInfo { log("ax.focusedElement"); return info }
        func setFocusedValue(_ value: String) throws { log("ax.setValue"); lock.withLock { _value = value; _postCount += 1 } }
        func setFocusedSelectedRange(_ range: Range<Int>) throws { log("ax.setSelectedRange") }
        func setFocusedSelectedText(_ text: String) throws { log("ax.setSelectedText"); insert(text) }
        func postUnicodeKeystrokes(_ text: String, toPID pid: Int32) throws { log("keystrokes→\(pid)"); insert(text) }
        func postKeyCombo(_ combo: KeyCombo, toPID pid: Int32) throws { log("keyCombo") }
        func readPasteboard() -> PasteboardSnapshot { PasteboardSnapshot(items: [], changeCount: 0) }
        func writePasteboard(string: String) -> Int { log("paste"); return 1 }
        func restorePasteboard(_ snapshot: PasteboardSnapshot) {}
        var pasteboardChangeCount: Int { 0 }
        func settle(milliseconds: Int) {}

        // InProcessTextDelivering — the real one refuses off the main thread; so does this.
        func ownFocusedText() -> FocusedElementInfo? {
            log("own.read")
            guard Thread.isMainThread, hasTextResponder else { return nil }
            return info
        }

        func insertIntoOwnFocusedText(_ text: String) throws -> Bool {
            log("own.insert")
            guard Thread.isMainThread else { throw SystemAccessError.ownProcessOffMain }
            guard hasTextResponder else { return false }
            insert(text)
            return true
        }
    }

    /// Runs `work` on a GCD background thread (never the cooperative pool: the hop blocks it).
    static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                precondition(!Thread.isMainThread)
                continuation.resume(returning: work())
            }
        }
    }

    /// A parallel test run can keep the main thread busy for longer than the live timeouts; the
    /// give-up path has its own test (`hopGivesUpOnBusyMain`).
    @discardableResult static func patient(_ live: LiveSystemAccess) -> LiveSystemAccess {
        live.mainThreadReadTimeout = 30
        live.mainThreadWriteTimeout = 30
        return live
    }

    static func patient(_ injector: TextInjector) -> TextInjector {
        injector.mainThreadWriteTimeout = 30
        return injector
    }

    // MARK: Routing

    @Test("a write into our own window from a background thread runs on the main thread, in-process, never AX")
    func ownProcessWriteRunsOnMainInProcess() async {
        let spy = Spy(frontmost: Self.own)
        let injector = Self.patient(TextInjector(system: spy))
        let outcome = await Self.offMain { injector.inject(InjectionRequest(text: "world", expectedFocus: Self.own)) }

        #expect(outcome == .injected(method: .adapter, verified: true))
        #expect(spy.value == "Hello world")
        #expect(spy.axWrites.isEmpty, "no AX setter ever runs for our own process")
        #expect(spy.names("own.insert").map(\.onMain) == [true], "the one insert ran on the main thread")
        // Once the stack is on main, every read it makes is there too. Only the routing decision —
        // `frontmostApp()`, no AX into ourselves — is made before the hop.
        let offMain = spy.calls.filter { !$0.onMain }.map(\.name)
        #expect(offMain.allSatisfy { $0 == "frontmostApp" }, "off-main calls: \(offMain)")
        #expect(!spy.calls.filter { $0.name == "ax.focusedElement" || $0.name == "own.read" }.isEmpty)
    }

    @Test("the turn's keyed commit (the lander's path) takes the same route")
    func keyedCommitRoutesOwnProcessToMain() async {
        let spy = Spy(frontmost: Self.own)
        let injector = Self.patient(TextInjector(system: spy))
        let key = TurnCommitKey(turnID: TurnID(), revision: 1)
        let result = await Self.offMain { injector.commit(InjectionRequest(text: "again", expectedFocus: Self.own), key: key) }

        #expect(result.report?.outcome == .injected(method: .adapter, verified: true))
        #expect(spy.value == "Hello again")
        #expect(spy.axWrites.isEmpty)
        #expect(spy.names("own.insert").allSatisfy { $0.onMain })
        let second = await Self.offMain { injector.commit(InjectionRequest(text: "again", expectedFocus: Self.own), key: key) }
        #expect(second.isDuplicate, "still inserted exactly once")
        #expect(spy.value == "Hello again")
    }

    @Test("snapshot names another app but ours is frontmost now: routed to main before anything is read")
    func frontmostOwnProcessAloneRoutesToMain() async {
        let spy = Spy(frontmost: Self.own)
        let injector = Self.patient(TextInjector(system: spy))
        #expect(injector.targetsOwnProcess(InjectionRequest(text: "x", expectedFocus: Self.textEdit)))
        let outcome = await Self.offMain { injector.inject(InjectionRequest(text: "x", expectedFocus: Self.textEdit)) }
        // Focus moved to us: held, nothing posted — and the check itself ran on main.
        #expect(outcome == .abortedFocusChanged(expected: Self.textEdit, actual: Self.own))
        #expect(spy.postCount == 0)
        #expect(spy.calls.filter { $0.name != "frontmostApp" }.allSatisfy { $0.onMain })
    }

    @Test("our first responder is not text: keystrokes through the main run loop, still never AX")
    func noTextResponderFallsBackToKeystrokes() async {
        let spy = Spy(frontmost: Self.own)
        spy.hasTextResponder = false
        let injector = Self.patient(TextInjector(system: spy))
        let outcome = await Self.offMain { injector.inject(InjectionRequest(text: "!", expectedFocus: Self.own)) }

        #expect(outcome == .injected(method: .keystroke, verified: true))
        #expect(spy.axWrites.isEmpty)
        #expect(spy.names("keystrokes→\(OwnProcess.pid)").map(\.onMain) == [true])
    }

    @Test("a secure field of ours is refused before any method runs")
    func ownSecureFieldIsRefused() async {
        let spy = Spy(frontmost: Self.own)
        spy.role = FocusedElementInfo.secureRole
        let injector = Self.patient(TextInjector(system: spy))
        let outcome = await Self.offMain { injector.inject(InjectionRequest(text: "hunter2", expectedFocus: Self.own)) }
        #expect(outcome == .refused(.secureField))
        #expect(spy.postCount == 0)
    }

    @Test("another app is untouched: AX first, from the calling thread, as before")
    func otherAppsKeepTheirPath() async {
        let spy = Spy(frontmost: Self.textEdit)
        let injector = Self.patient(TextInjector(system: spy))
        let outcome = await Self.offMain { injector.inject(InjectionRequest(text: "world", expectedFocus: Self.textEdit)) }
        #expect(outcome == .injected(method: .ax, verified: true))
        #expect(spy.names("ax.setSelectedText").map(\.onMain) == [false], "no main-thread hop for other apps")
        #expect(spy.names("own.insert").isEmpty)
    }

    @Test("called on the main thread it runs inline")
    @MainActor func onMainRunsInline() {
        let spy = Spy(frontmost: Self.own)
        let outcome = TextInjector(system: spy).inject(InjectionRequest(text: "there", expectedFocus: Self.own))
        #expect(outcome == .injected(method: .adapter, verified: true))
        #expect(spy.calls.allSatisfy { $0.onMain })
    }

    @Test("own process: our pid, or our bundle ID")
    func ownProcessIdentity() {
        #expect(OwnProcess.owns(FocusSnapshot(pid: OwnProcess.pid, bundleID: "anything")))
        #expect(OwnProcess.owns(FocusSnapshot(pid: 4242, bundleID: "in.adityakatare.voiceplus"), bundleID: "in.adityakatare.voiceplus"))
        #expect(!OwnProcess.owns(FocusSnapshot(pid: 4242, bundleID: "com.apple.TextEdit"), bundleID: "in.adityakatare.voiceplus"))
        #expect(!OwnProcess.owns(FocusSnapshot(pid: 4242, bundleID: ""), bundleID: nil))
        #expect(!OwnProcess.owns(nil))
        #expect(OwnProcessAdapter().methodOrder == [.adapter, .keystroke], "never .ax, never paste")
        #expect(!AdapterRegistry.standard().adapters.contains { $0 is OwnProcessAdapter }, "no other bundle can match it")
    }

    // MARK: The main-thread hop

    @Test("MainThreadHop runs the work on the main thread and returns its value")
    func hopRunsOnMain() async throws {
        // Generous start timeouts here: a parallel test run can keep the main thread busy for a while.
        let ran = await Self.offMain { (try? MainThreadHop.run(startTimeout: 30) { Thread.isMainThread }) ?? false }
        #expect(ran)
        let thrown = await Self.offMain { () -> Bool in
            do { _ = try MainThreadHop.run(startTimeout: 30) { () throws -> Int in throw SystemAccessError.noFocusedElement }; return false }
            catch { return (error as? SystemAccessError) == .noFocusedElement }
        }
        #expect(thrown, "the work's own error comes back to the caller")
    }

    /// The deadlock-proof property: a caller never waits on a main thread that is not answering,
    /// and work it gave up on never runs later (a timed-out write can never land late).
    @Test("a busy main thread: the hop gives up in time and the work never runs")
    func hopGivesUpOnBusyMain() async throws {
        let ran = Flag()
        let blocked = Flag()
        DispatchQueue.main.async { blocked.set(); Thread.sleep(forTimeInterval: 0.4) }
        let error = await Self.offMain { () -> SystemAccessError? in
            while !blocked.isSet { usleep(1_000) }   // the main thread is now asleep
            do { _ = try MainThreadHop.run(startTimeout: 0.05) { ran.set() }; return nil }
            catch { return error as? SystemAccessError }
        }
        #expect(error == .mainThreadBusy)
        await MainActor.run {}   // queued behind the cancelled work: it has had its chance to run
        #expect(!ran.isSet, "cancelled before it started: never runs")
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    // MARK: LiveSystemAccess — the guard itself, and the real in-process path

    @Test("LiveSystemAccess's guard: our process goes to main; other apps stay on the caller; a late discovery retries on main")
    func liveGuardRoutes() async {
        let live = Self.patient(LiveSystemAccess())
        let own = await Self.offMain { (try? live.onSafeThread(ownProcess: true) { Thread.isMainThread }) ?? false }
        #expect(own)
        let other = await Self.offMain { (try? live.onSafeThread(ownProcess: false) { Thread.isMainThread }) ?? true }
        #expect(!other)
        let attempts = Counter()
        let retried = await Self.offMain { () -> Bool in
            (try? live.onSafeThread(ownProcess: false) { () throws -> Bool in
                attempts.bump()
                if !Thread.isMainThread { throw SystemAccessError.ownProcessOffMain }
                return true
            }) ?? false
        }
        #expect(retried)
        #expect(attempts.value == 2, "one refused off main, one on main")
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    /// An off-screen window holding a TextKit 2 text view, as our own first responder.
    final class OwnWindow: @unchecked Sendable {
        let window: NSWindow
        let textView: NSTextView

        @MainActor init(text: String) {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 320, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
            window.contentView = textView
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }

        @MainActor var text: String { textView.string }

        @MainActor func point(_ live: LiveSystemAccess) {
            live.frontmostApplication = { NSRunningApplication.current }
            live.ownTextResponder = { [textView] in textView }
            _ = OwnProcessRoutingTests.patient(live)
        }
    }

    @Test("LiveSystemAccess reads our own text view on the main thread and writes it only there")
    func liveInProcessPath() async throws {
        let target = await MainActor.run { OwnWindow(text: "Dear Mira, ") }
        let live = LiveSystemAccess()
        await MainActor.run { target.point(live) }

        // A background read of our own focused element hops to main and reads the view directly.
        let read = await Self.offMain { try? live.focusedElement() }
        #expect(read?.value == "Dear Mira, ")
        #expect(read?.selectedRange == 11..<11)
        #expect(read?.role == "AXTextArea")

        // A background write is refused before anything is touched.
        let refused = await Self.offMain { () -> SystemAccessError? in
            do { _ = try live.insertIntoOwnFocusedText("no"); return nil } catch { return error as? SystemAccessError }
        }
        #expect(refused == .ownProcessOffMain)
        #expect(live.postCount == 0)

        // On the main thread it types, like a key press would.
        let inserted = try await MainActor.run { try live.insertIntoOwnFocusedText("hello") }
        #expect(inserted)
        #expect(live.postCount == 1)
        #expect(await MainActor.run { target.text } == "Dear Mira, hello")
        let after = await MainActor.run { live.ownFocusedText() }
        #expect(after?.selectedRange == 16..<16, "the caret sits after the insertion")
    }

    @Test("the whole injector over LiveSystemAccess lands text in our own text view from a background thread")
    func liveInjectorLandsInOwnTextView() async throws {
        let target = await MainActor.run { OwnWindow(text: "Dear Mira, ") }
        let live = LiveSystemAccess()
        await MainActor.run { target.point(live) }
        let injector = Self.patient(TextInjector(system: live))
        let expected = live.frontmostApp()
        #expect(expected?.pid == OwnProcess.pid)

        let outcome = await Self.offMain { injector.inject(InjectionRequest(text: "see you Friday", expectedFocus: expected)) }
        #expect(outcome == .injected(method: .adapter, verified: true))
        #expect(await MainActor.run { target.text } == "Dear Mira, see you Friday")
    }
}
