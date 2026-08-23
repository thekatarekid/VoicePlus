import Foundation
import Testing
import Shared
@testable import Pipeline

/// Scripted utterances: (text, expected route). Register expectations are separate below.
private let scriptedRoutes: [(String, Utterance.Route)] = [
    // repair commands (Bet 3 / Bet 9 voice repair)
    ("no, Thursday", .repairCommand), ("no Kothari", .repairCommand), ("nope, TeamViewer", .repairCommand),
    ("not that one", .repairCommand), ("scratch that", .repairCommand), ("undo that", .repairCommand),
    ("undo", .repairCommand), ("put it back", .repairCommand), ("go back", .repairCommand),
    ("delete the last sentence", .repairCommand), ("delete the last word", .repairCommand),
    ("replace Monday with Friday", .repairCommand), ("change Priya to Preeti", .repairCommand),
    ("I said kubectl", .repairCommand), ("I meant Anthropic", .repairCommand), ("spell it K O T H A R I", .repairCommand),
    ("strike that", .repairCommand), ("erase that", .repairCommand), ("never mind", .repairCommand),
    ("that's wrong, it's Sundar", .repairCommand), ("the second one", .repairCommand), ("capital T", .repairCommand),
    // transforms
    ("make this shorter", .transform), ("make it more formal", .transform), ("make it casual", .transform),
    ("rewrite this as an email", .transform), ("summarize this", .transform), ("turn this into a list", .transform),
    ("translate this to Hindi", .transform), ("fix the grammar", .transform), ("make it sound friendlier", .transform),
    ("tighten this up", .transform), ("convert this to bullet points", .transform), ("simplify this", .transform),
    ("clean this up", .transform), ("make it less aggressive", .transform), ("shorten this paragraph", .transform),
    ("paraphrase that", .transform),
    // questions about the text
    ("what does this say", .question), ("what is this about", .question), ("who sent this", .question),
    ("does this sound okay", .question),
    // dictation — including sentences that contain command-like words
    ("hi team, the deploy is scheduled for Thursday at ten", .dictate),
    ("thanks for the update, see you tomorrow", .dictate),
    ("can you send me the report by Friday", .dictate),
    ("let's meet at the coffee shop near the office", .dictate),
    ("the function returns a promise that resolves with the user", .dictate),
    ("git commit dash m fix typo", .dictate),
    ("I think we should push the launch to next week", .dictate),
    ("please find attached the invoice for last month", .dictate),
    ("sounds good, I'll take a look", .dictate),
    ("new paragraph", .dictate), ("new line", .dictate),
    ("lol that's hilarious", .dictate),
    ("remind me to call the dentist on Monday", .dictate),
    ("not sure yet, will confirm tomorrow", .dictate),
    ("no worries, take your time", .dictate),
    ("make sure to bring the charger and the adapter", .dictate),
    ("I'm not going to make it tonight, sorry", .dictate),
    ("what time works for you", .dictate),
    ("the quarterly numbers look strong this time", .dictate),
    ("cd into the project and run the tests", .dictate),
    ("we changed the plan to Friday because the venue was booked", .dictate),
    ("delete the old branch after merging so the list stays clean", .dictate),
    ("kubectl get pods dash n production", .dictate),
    ("dear Mr Kothari, thank you for your time yesterday", .dictate),
    ("it was nice meeting you yesterday at the conference", .dictate),
    ("I'll replace the battery this weekend if the shop has one", .dictate),
    ("okay so the idea is that we ship the pipeline first", .dictate),
    ("hey are you around", .dictate),
    ("the weather is nice today", .dictate),
    ("make a note that the invoice is overdue", .dictate),
]

private func manifestTranscripts() -> [String] {
    guard let dir = AppPaths.fixturesDirectory() else { return [] }
    let url = dir.appendingPathComponent("audio/commands/manifest.json")
    guard let data = try? Data(contentsOf: url),
          let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return items.compactMap { $0["transcript"] as? String }
}

@Suite struct GatekeeperRoutingTests {
    let gatekeeper = LocalGatekeeper.shared
    let context = StageContext()

    @Test func corpusHasAtLeastSixtyUtterances() {
        #expect(scriptedRoutes.count + manifestTranscripts().count >= 60)
    }

    @Test func routingAccuracyOnScriptedUtterances() {
        var failures: [String] = []
        for (text, expected) in scriptedRoutes {
            let d = gatekeeper.classify(text, context: context)
            if d.route != expected { failures.append("\"\(text)\" -> \(d.route) (\(d.routeSource), \(d.routeConfidence)) expected \(expected)") }
        }
        let accuracy = 1 - Double(failures.count) / Double(scriptedRoutes.count)
        #expect(accuracy >= 0.95, "accuracy \(accuracy): \(failures.joined(separator: "\n"))")
    }

    @Test func manifestCommandsAreNotDictationExceptFormattingCommands() {
        let transcripts = manifestTranscripts()
        #expect(transcripts.count == 10)
        for t in transcripts {
            let d = gatekeeper.classify(t, context: context)
            if t == "new paragraph" { #expect(d.route == .dictate, Comment(rawValue: t)) }
            else { #expect(d.route == .repairCommand || d.route == .transform, "\(t) -> \(d.route)") }
        }
    }

    @Test func emptyAndFillerOnlyRouteToNone() {
        #expect(gatekeeper.classify("", context: context).route == .none)
        #expect(gatekeeper.classify("um uh hmm", context: context).route == .none)
    }

    @Test func lowConfidenceFallsBackToDictate() {
        let strict = LocalGatekeeper(routeThreshold: 1.01)
        let d = strict.classify("zebra quantum lattice pancake", context: context)
        #expect(d.route == .dictate)
        #expect(d.routeSource == .fallback)
    }

    @Test func voiceRepairFlagOffForcesDictation() {
        let ctx = StageContext(flags: [FeatureFlag.voiceRepair.id: false])
        #expect(gatekeeper.classify("scratch that", context: ctx).route == .dictate)
    }

    @Test func registerFromContextWinsOverText() {
        let d = gatekeeper.classify("git push origin main", context: StageContext(register: .email))
        #expect(d.register == .email)
        #expect(d.registerSource == .context)
    }

    @Test func registerFromBundleID() {
        let pairs: [(String, Utterance.Register)] = [
            ("com.apple.mail", .email), ("com.tinyspeck.slackmacgap", .chat), ("com.apple.Terminal", .terminal),
            ("com.microsoft.VSCode", .code), ("com.apple.Notes", .prose), ("com.apple.reminders", .list),
        ]
        for (bundle, reg) in pairs {
            #expect(gatekeeper.classify("hello there", context: StageContext(appBundleID: bundle)).register == reg, Comment(rawValue: bundle))
        }
    }

    @Test func registerFromTextWhenNoContext() {
        let cases: [(String, Utterance.Register)] = [
            ("dear Mr Kothari, thank you for your time. best regards", .email),
            ("git push origin main", .terminal), ("lol ok see you at 5", .chat),
            ("const result equals await fetch data", .code),
            ("item one milk item two eggs item three bread", .list),
        ]
        var hits = 0
        for (text, reg) in cases where gatekeeper.classify(text, context: context).register == reg { hits += 1 }
        #expect(hits >= 4, "only \(hits)/\(cases.count) registers correct")
    }

    @Test func unknownRegisterWhenTextIsAmbiguous() {
        let strict = LocalGatekeeper(registerThreshold: 1.01)
        #expect(strict.classify("hello", context: context).register == .unknown)
    }
}
