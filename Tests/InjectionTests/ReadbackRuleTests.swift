import Foundation
import Testing
import Shared
@testable import Injection

// MARK: - R2.3: the readback rule, the Chromium adapter, and the two refusals

/// The regression this whole item exists for. On the owner's Mac, seven of twenty dictations into
/// Brave logged `keystroke failed … readback unchanged` and then `paste failed … readback unchanged`
/// (V3 §2.2). Both methods had posted, so the text landed twice and the outcome was filed as a
/// failure. These tests assert that log pattern is now unreachable.
@Suite struct ReadbackRuleTests {
    @Test func theBraveDoubleFirePatternCannotHappen() {
        // Brave, keystrokes posted and swallowed by Blink, AX value never reflecting the change.
        let (injector, mock, store) = makeStack("com.brave.Browser") { $0.keystrokesWork = false }
        let outcome = injector.inject(InjectionRequest(text: "hello there", expectedFocus: mock.frontmost))

        #expect(outcome == .injected(method: .keystroke, verified: false))
        #expect(outcome.delivery == .delivered(verified: false, method: "keystroke"))
        // Exactly one method ran, exactly one thing was posted, and paste never happened.
        #expect(mock.postCount == 1)
        #expect(store.records.count == 1)
        #expect(!mock.journal.contains { $0.hasPrefix("key.combo") })
        // And no row in the log says "failed" — the pattern the owner saw is two of those in a row.
        #expect(store.records.allSatisfy { $0.method != "paste" })
    }

    @Test("no second method after one has posted, whatever the app",
          arguments: ["com.brave.Browser", "com.google.Chrome", "com.apple.TextEdit",
                      "com.tinyspeck.slackmacgap", "com.apple.Terminal", "com.figma.Desktop"])
    func atMostOnePostedMethodPerRequest(bundleID: String) {
        for keystrokes in [true, false] {
            for axWrites in [true, false] {
                let (injector, mock, store) = makeStack(bundleID) {
                    $0.keystrokesWork = keystrokes; $0.axWriteWorks = axWrites; $0.pasteWorks = false
                }
                let outcome = injector.inject(InjectionRequest(text: "one", expectedFocus: mock.frontmost))
                #expect(mock.postCount <= 1, "\(bundleID) posted \(mock.postCount) times")
                #expect(store.records.count <= 1, "\(bundleID) recorded \(store.records.count) attempts")
                if case .failed = outcome { Issue.record("\(bundleID): a posted method must never read as failed") }
            }
        }
    }

    // MARK: ChromiumAdapter

    @Test("Chromium browsers all route through the Chromium adapter",
          arguments: ["com.brave.Browser", "com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.Browser",
                      "com.google.Chrome.canary", "com.brave.Browser.beta", "com.microsoft.edgemac.Dev"])
    func chromiumAdapterMatches(bundleID: String) {
        #expect(AdapterRegistry.standard().adapter(for: bundleID).id == "chromium")
    }

    @Test func chromiumOrderIsKeystrokeThenPasteAndNeverAX() {
        // AX value writes desync Blink's own model exactly as they do in Electron.
        #expect(ChromiumAdapter().methodOrder == [.keystroke, .paste])
    }

    @Test func chromiumIsRegisteredBeforeDefault() throws {
        let ids = AdapterRegistry.standard().adapters.map(\.id)
        let chromium = try #require(ids.firstIndex(of: "chromium"))
        let fallback = try #require(ids.firstIndex(of: "default"))
        #expect(chromium < fallback)
    }

    @Test func chromiumConfirmsByCaretWhenTheAXValueIsUnreadable() {
        // Web content: no readable AXValue, but a live caret.
        let (injector, mock, store) = makeStack("com.brave.Browser") { $0.axReadable = false; $0.axCaretReadable = true }
        let outcome = injector.inject(InjectionRequest(text: "hello", expectedFocus: mock.frontmost))
        #expect(outcome == .injected(method: .keystroke, verified: true))
        #expect(store.records.first?.detail == "verified")
    }

    @Test func chromiumSkipsVerificationWhenNeitherValueNorCaretIsAvailable() {
        let (injector, mock, store) = makeStack("com.brave.Browser") { $0.axReadable = false; $0.axCaretReadable = false }
        let outcome = injector.inject(InjectionRequest(text: "hello", expectedFocus: mock.frontmost))
        // Skipped, not failed.
        #expect(outcome == .injected(method: .keystroke, verified: false))
        #expect(store.records.first?.detail == "unverified: readback unavailable")
        #expect(store.records.first?.succeeded == true)
    }

    @Test func chromiumPastesOnlyWhenKeystrokesThrewBeforePosting() {
        let (injector, mock, _) = makeStack("com.google.Chrome") { $0.throwsBeforePosting = [.keystrokes] }
        #expect(injector.inject(InjectionRequest(text: "pasted")) == .injected(method: .paste, verified: true))
        #expect(mock.field.value == "pasted")
    }

    @Test func readbackVerdictDetailsAreStable() {
        #expect(ReadbackVerdict.confirmed.detail == "verified")
        #expect(ReadbackVerdict.unconfirmed.detail == "unverified: readback unchanged")
        #expect(ReadbackVerdict.unavailable.detail == "unverified: readback unavailable")
        #expect(ReadbackVerdict.confirmed.isConfirmed)
        #expect(!ReadbackVerdict.unavailable.isConfirmed)
    }

    // MARK: Secure fields

    @Test("a password field is refused with nothing posted", arguments: [false, true])
    func secureFieldRefusalPostsNothing(webStyle: Bool) {
        let (injector, mock, store) = makeStack("com.apple.Safari") { $0.field = .secure(webStyle: webStyle) }
        let outcome = injector.inject(InjectionRequest(text: "hunter2", expectedFocus: mock.frontmost))
        #expect(outcome == .refused(.secureField))
        #expect(mock.journal.isEmpty)
        #expect(mock.postCount == 0)
        #expect(mock.field.value == "")
        #expect(mock.pasteboardString == nil)               // not even via the clipboard
        // A refused password is not kept in memory, and it is terminal: there is nothing to recover.
        #expect(injector.focusGuard.held.isEmpty)
        #expect(outcome.delivery == .failed(reason: "secure field"))
        #expect(outcome.delivery.isTerminal)
        #expect(store.records.first?.method == "refused")
        #expect(store.records.first?.detail == "secure field")
    }

    @Test func secureRefusalIsIndependentOfTheAdapter() {
        for bundleID in ["com.brave.Browser", "com.apple.Terminal", "com.microsoft.VSCode", "com.apple.TextEdit"] {
            let (injector, mock, _) = makeStack(bundleID) { $0.field = .secure() }
            #expect(injector.inject(InjectionRequest(text: "pw")) == .refused(.secureField))
            #expect(mock.postCount == 0, "\(bundleID)")
        }
    }

    // MARK: Never-inject list

    @Test func neverInjectAppIsRefusedAndHeld() {
        let (injector, mock, store) = makeStack("com.agilebits.onepassword7")
        injector.policy = StaticInjectionPolicy(neverInject: ["com.agilebits.onepassword7"])
        let outcome = injector.inject(InjectionRequest(text: "a note", expectedFocus: mock.frontmost))
        #expect(outcome == .refused(.neverInject))
        #expect(mock.journal.isEmpty)
        #expect(mock.postCount == 0)
        // Refused for routing, not for secrecy: the text survives as held so the user can place it.
        #expect(injector.focusGuard.held.count == 1)
        #expect(injector.focusGuard.held.first?.reason == DeliveryReason.neverInject)
        #expect(outcome.delivery == .held(reason: "never-inject list"))
        #expect(!outcome.delivery.isTerminal)
        #expect(store.records.first?.method == "refused")
    }

    @Test func heldNeverInjectTextCanBeInsertedIntoADifferentApp() {
        let (injector, mock, _) = makeStack("com.agilebits.onepassword7")
        injector.policy = StaticInjectionPolicy(neverInject: ["com.agilebits.onepassword7"])
        _ = injector.inject(InjectionRequest(text: "a note", expectedFocus: mock.frontmost))
        mock.frontmost = focus("com.apple.Notes", pid: 500)
        #expect(injector.focusGuard.insertHere()?.succeeded == true)
        #expect(mock.field.value == "a note")
        #expect(injector.focusGuard.held.isEmpty)
    }

    @Test func appsNotOnTheListAreUnaffected() {
        let (injector, mock, _) = makeStack("com.apple.TextEdit")
        injector.policy = StaticInjectionPolicy(neverInject: ["com.agilebits.onepassword7"])
        #expect(injector.inject(InjectionRequest(text: "fine")).succeeded)
        #expect(mock.field.value == "fine")
    }

    @Test func noPolicyMeansNothingIsRefusedForRouting() {
        let (injector, _, _) = makeStack("com.agilebits.onepassword7")
        #expect(injector.policy == nil)
        #expect(injector.inject(InjectionRequest(text: "fine")).succeeded)
    }

    @Test func neverInjectSettingParsesCommasNewlinesAndStrayWhitespace() {
        let parsed = InjectionSettingsKeys.parseBundleIDs(" com.a , com.b\ncom.c ;;\n\n com.a ")
        #expect(parsed == ["com.a", "com.b", "com.c"])
        #expect(InjectionSettingsKeys.parseBundleIDs(nil).isEmpty)
        #expect(InjectionSettingsKeys.parseBundleIDs("").isEmpty)
        #expect(InjectionSettingsKeys.format(["com.b", "com.a"]) == "com.a,com.b")
    }

    @Test func userDefaultsPolicyReadsTheSettingOnEveryCall() {
        let key = InjectionSettingsKeys.neverInject
        let defaults = UserDefaults(suiteName: "in.adityakatare.voiceplus.tests.injection")!
        defaults.removeObject(forKey: key)
        let policy = UserDefaultsInjectionPolicy(defaults: defaults)
        #expect(policy.neverInjectBundleIDs.isEmpty)          // default is empty: no surprises
        defaults.set("com.one, com.two", forKey: key)
        #expect(policy.neverInjectBundleIDs == ["com.one", "com.two"])
        defaults.set(["com.three"], forKey: key)              // an array works too
        #expect(policy.neverInjectBundleIDs == ["com.three"])
        defaults.removeObject(forKey: key)
        #expect(policy.neverInjectBundleIDs.isEmpty)
    }

    @Test func refusalReasonsRoundTripThroughDeliveryReason() {
        #expect(InjectionRefusal.secureField.rawValue == DeliveryReason.secureField)
        #expect(InjectionRefusal.neverInject.rawValue == DeliveryReason.neverInject)
        #expect(!InjectionRefusal.secureField.holdsText)
        #expect(InjectionRefusal.neverInject.holdsText)
    }
}
