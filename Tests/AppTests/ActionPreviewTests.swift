import Actions
import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// S12 — outbound action preview (design_v1 §8.8): the card names the destination and the proposed
/// action; outbound catalogue actions wait behind it instead of running first; only an explicit
/// confirm runs them; a dictation is never sent because it was inserted; nothing presses Enter/Send.
@Suite("S12 — outbound action preview")
struct ActionPreviewTests {
    // MARK: Copy

    @Test func previewCopyNamesTheDestinationAndTheProposedAction() {
        let send = ActionPreview(card: ConfirmationCard(actionID: "chat.send", title: "shortcut"), destination: "Slack")
        #expect(send.headline == "Send message · Slack")
        #expect(send.detail == "Nothing is sent until you choose Send.")
        #expect(send.footnote == "Inserted text is never sent on its own. Say “confirm” or click.")
        #expect(send.confirmLabel == "Send" && ActionPreview.cancelLabel == "Cancel" && send.isOutbound)

        let mail = ActionPreview(card: ConfirmationCard(actionID: "mail.send_mail", title: "shortcut"), destination: "Mail")
        #expect(mail.headline == "Send email · Mail" && mail.confirmLabel == "Send")
        let later = ActionPreview(card: ConfirmationCard(actionID: "mail.click_schedule", title: "Send Later"), destination: "Mail")
        #expect(later.headline == "Schedule email · Mail" && later.detail == "Nothing is sent until you choose Schedule.")
        let submit = ActionPreview(card: ConfirmationCard(actionID: "mac.click_submit", title: "Submit"), destination: "Safari")
        #expect(submit.headline == "Submit form · Safari" && submit.confirmLabel == "Submit")
        let comment = ActionPreview(card: ConfirmationCard(actionID: "browser.click_comment", title: "Comment"), destination: "Safari")
        #expect(comment.headline == "Post comment · Safari" && comment.confirmLabel == "Post")

        // An agent step: named from its title, still recognised as a send.
        let agent = ActionPreview(card: ConfirmationCard(actionID: "ax.click", title: "click Send"), destination: "Messages")
        #expect(agent.headline == "Click Send · Messages" && agent.confirmLabel == "Send" && agent.isOutbound)

        // Not outbound: the destructive-action card keeps the same anatomy with Confirm.
        let delete = ActionPreview(card: ConfirmationCard(actionID: "fs.delete", title: "delete report.pdf"), destination: "Finder")
        #expect(delete.headline == "Delete report.pdf · Finder" && !delete.isOutbound)
        #expect(delete.detail == "Nothing happens until you choose Confirm." && delete.footnote == "Say “confirm” or click.")

        // No known destination: the action alone, never an invented name.
        let nowhere = ActionPreview(card: ConfirmationCard(actionID: "chat.send", title: ""), destination: "  ")
        #expect(nowhere.destination == nil && nowhere.headline == "Send message")
        #expect(ActionPreview(card: ConfirmationCard(actionID: "x.y", title: " "), destination: nil).headline == "Run this action")
    }

    @Test func copyNeverLeaksAnActionID() throws {
        let catalog = try ActionCatalog.load()
        for entry in catalog.entries where ActionPreviewPolicy.isOutbound(entry) {
            let p = ActionPreview(card: ConfirmationCard(actionID: entry.id, title: entry.params["name"] ?? entry.kind.rawValue), destination: "App")
            #expect(!p.headline.contains(entry.id) && !p.headline.contains("_") && !p.headline.contains("."), "\(entry.id): \(p.headline)")
        }
    }

    // MARK: Policy over the shipped catalogue

    static let shippedOutbound: Set<String> = ["mac.click_submit", "browser.click_comment", "chat.click_send", "chat.send",
                                               "mail.click_send", "mail.click_schedule", "mail.send_mail"]

    @Test func outboundCatalogueActionsAreExactlyTheSends() throws {
        let catalog = try ActionCatalog.load()
        let outbound = Set(catalog.entries.filter(ActionPreviewPolicy.isOutbound).map(\.id))
        #expect(outbound == Self.shippedOutbound)
        // Not sends: an explicit keystroke command, compose/reply windows, newlines, renames.
        for id in ["mac.press_enter", "mail.click_reply", "mail.reply_key", "mail.forward_mail", "chat.click_reply_thread",
                   "chat.newline", "files.rename", "editor.toggle_comment"] {
            #expect(!outbound.contains(id), "\(id)")
        }
    }

    @Test func previewingOutboundRaisesOnlyTheSendsAndChangesNothingElse() throws {
        let catalog = try ActionCatalog.load()
        let previewed = ActionPreviewPolicy.previewingOutbound(catalog)
        #expect(previewed.entries.map(\.id) == catalog.entries.map(\.id))
        for (before, after) in zip(catalog.entries, previewed.entries) {
            if Self.shippedOutbound.contains(before.id) {
                #expect(after.reversibility == .irreversible, "\(before.id)")
            } else {
                #expect(after == before, "\(before.id) must be untouched")
            }
            #expect(after.phrasings == before.phrasings && after.params == before.params && after.apps == before.apps)
        }
        let classifier = ActionClassifier()
        for id in Self.shippedOutbound {
            let entry = try #require(previewed.entry(id: id))
            #expect(classifier.classify(ConsentRequest.forAction(ActionRequest(entry))) == .irreversible, "\(id) waits for its card")
        }
    }

    // MARK: End to end over the act router

    static func slack() -> MockActionSystem {
        let system = MockActionSystem()
        let bundle = "com.tinyspeck.slackmacgap"
        let window = WindowRef(id: 1, appBundleID: bundle, title: "general")
        system.add(MockActionSystem.MockApp(ref: AppRef(name: "Slack", bundleID: bundle), kind: .chat,
                                            windows: [window], elements: [1: []]))
        system.bringToFront(bundle)
        return system
    }

    static func router(_ catalog: ActionCatalog, system: MockActionSystem) -> (ActRouter, ConsentEngine) {
        let consent = ConsentEngine()
        let executor = ActionExecutor(system: system)
        let agent = NativeAgentBackend(planner: ScriptedPlanner([]), executor: executor, consent: consent)
        let router = ActRouter(parser: ActIntentParser(catalog: catalog, activation: ActDomainState(active: true)),
                               consent: consent, executor: executor, agent: agent)
        return (router, consent)
    }

    @Test func spokenSendWaitsForThePreviewAndRunsOnlyOnConfirm() async throws {
        let catalog = try ActionCatalog.load()

        // Before S12: "send" in a chat app pressed Return at once (semi-reversible, undo afterwards).
        let legacySystem = Self.slack()
        let (legacy, _) = Self.router(catalog, system: legacySystem)
        _ = try await legacy.handle("send", appBundleID: "com.tinyspeck.slackmacgap")
        #expect(legacySystem.log.contains { $0.hasPrefix("key") }, "the unpreviewed catalogue sends immediately")

        // With the preview: the card comes first and nothing is pressed.
        let system = Self.slack()
        let (router, consent) = Self.router(ActionPreviewPolicy.previewingOutbound(catalog), system: system)
        let cards = TransformPreviewGateTests.Box<[ConfirmationCard]>([])
        consent.onCard = { _, card in cards.value.append(card) }
        let dispatch = try await router.handle("send", appBundleID: "com.tinyspeck.slackmacgap")
        guard case .deterministic(nil, .awaitingConfirmation(let card)) = dispatch else {
            Issue.record("expected the preview card first, got \(dispatch)"); return
        }
        #expect(system.log.isEmpty, "nothing pressed before the confirm")
        #expect(card.actionID == "chat.send" && cards.value.count == 1)
        #expect(ActionPreview(card: card, destination: "Slack").headline == "Send message · Slack")
        #expect(router.hasPendingConfirmation)

        // An explicit confirm runs it — once.
        _ = try await router.dispatch(.confirm)
        #expect(system.log.filter { $0.hasPrefix("key") }.count == 1)
        _ = try await router.dispatch(.confirm)
        #expect(system.log.filter { $0.hasPrefix("key") }.count == 1, "a second confirm sends nothing")
    }

    // MARK: The gate

    @Test func onlyAnExplicitConfirmRunsThePreview() {
        let preview = ActionPreview(card: ConfirmationCard(actionID: "chat.send", title: ""), destination: "Slack")
        var gate = ActionPreviewGate(preview: preview)
        // A dictation landing in the destination, time passing and focus moving never send.
        for event: ActionPreviewGate.Event in [.dictationInserted, .timePassed(3600), .focusChanged, .spoken("confirm the meeting"),
                                               .spoken("send it"), .spoken("")] {
            #expect(gate.handle(event) == .keepWaiting, "\(event)")
            #expect(gate.state == .pending)
        }
        #expect(gate.handle(.confirmClicked) == .run && gate.state == .confirmed)
        #expect(gate.handle(.confirmClicked) == .keepWaiting, "resolves once: no double send")
        #expect(gate.handle(.cancelClicked) == .keepWaiting && gate.state == .confirmed)

        var spoken = ActionPreviewGate(preview: preview)
        #expect(spoken.handle(.spoken("Confirm.")) == .run)
        var cancelled = ActionPreviewGate(preview: preview)
        #expect(cancelled.handle(.spoken("never mind")) == .cancel && cancelled.state == .cancelled)
        #expect(cancelled.handle(.confirmClicked) == .keepWaiting, "a cancelled preview can't be revived")
    }

    @Test @MainActor func consentPanelResolvesOnlyThroughItsGate() async {
        let panels = ConsentPanelsController()
        panels.panelsEnabled = false
        panels.destinationName = { "Slack" }
        let card = ConfirmationCard(actionID: "chat.send", title: "shortcut")
        let answer = Task { @MainActor in await panels.requestAgentConfirmation(card) }
        while panels.visiblePreview == nil { await Task.yield() }
        #expect(panels.visiblePreview?.preview.headline == "Send message · Slack")
        #expect(panels.handlePreviewEvent(.dictationInserted) == .keepWaiting)
        #expect(panels.handlePreviewEvent(.timePassed(60)) == .keepWaiting)
        #expect(panels.visiblePreview?.state == .pending, "still waiting for the user")
        #expect(panels.handlePreviewEvent(.confirmClicked) == .run)
        #expect(await answer.value == true)
        #expect(panels.visiblePreview == nil, "the card comes down once resolved")

        let declined = Task { @MainActor in await panels.requestAgentConfirmation(card) }
        while panels.visiblePreview == nil { await Task.yield() }
        panels.resolveVisibleCard(confirmed: false)
        #expect(await declined.value == false)
    }

    // MARK: No automatic Enter / Send after a dictation

    @Test func dictatingSendItIntoAChatFieldTypesTheWordsAndPressesNothing() async {
        let system = MockSystemAccess(frontmost: FocusSnapshot(pid: 300, bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", elementToken: "msg"))
        system.field = .init(value: "", selection: 0..<0)
        let injector = TextInjector(system: system)
        let lander = UtteranceLander(pipeline: PipelineRunner.standard(), injector: injector, system: system, repair: nil,
                                     flags: .inMemory(), database: nil)
        let result = await lander.land(TransformLandingTests.spans("send it"), startedAt: Date(), focus: system.frontmost)
        #expect(result.injection?.succeeded == true)
        #expect(system.field.value.lowercased().contains("send it"), "the words were inserted as text")
        let returns = system.journal.filter { $0.hasPrefix("key.combo") && $0.hasSuffix(":\(KeyCombo.returnKey.keyCode)") }
        #expect(returns.isEmpty, "inserting a dictation never presses Return: \(system.journal)")
    }
}
