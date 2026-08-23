import Foundation
import Shared

/// Built-in seed corpus for the naive-Bayes half of the gatekeeper. Small on purpose:
/// rules handle the crisp cases; this handles the long tail and ties.
enum GatekeeperSeedCorpus {
    static let routes: [(Utterance.Route, String)] = [
        // repairCommand
        (.repairCommand, "no, Thursday"), (.repairCommand, "no Kothari"), (.repairCommand, "not that one"),
        (.repairCommand, "scratch that"), (.repairCommand, "undo that"), (.repairCommand, "put it back"),
        (.repairCommand, "delete the last sentence"), (.repairCommand, "delete the last word"),
        (.repairCommand, "replace Monday with Friday"), (.repairCommand, "change the name to Priya"),
        (.repairCommand, "I said TeamViewer"), (.repairCommand, "I meant kubectl"), (.repairCommand, "go back"),
        (.repairCommand, "spell it K O T H A R I"), (.repairCommand, "capital letters"), (.repairCommand, "remove that"),
        (.repairCommand, "that's wrong, it's Anthropic"), (.repairCommand, "no no, Sundar"), (.repairCommand, "erase that"),
        (.repairCommand, "strike that"), (.repairCommand, "never mind, delete it"), (.repairCommand, "fix the last word"),
        (.repairCommand, "the second one"), (.repairCommand, "the first option"), (.repairCommand, "redo"),
        // transform
        (.transform, "make this shorter"), (.transform, "make it more formal"), (.transform, "make it casual"),
        (.transform, "rewrite this as an email"), (.transform, "summarize this"), (.transform, "turn this into a list"),
        (.transform, "translate this to Hindi"), (.transform, "fix the grammar"), (.transform, "make it sound friendlier"),
        (.transform, "expand on this"), (.transform, "tighten this up"), (.transform, "convert this to bullet points"),
        (.transform, "make it less aggressive"), (.transform, "clean this up"), (.transform, "reply to this politely"),
        (.transform, "shorten the paragraph"), (.transform, "make this a tweet"), (.transform, "simplify this"),
        (.transform, "add a greeting"), (.transform, "make it sound like me"), (.transform, "turn this into code"),
        // question
        (.question, "what does this say"), (.question, "what is this about"), (.question, "who sent this"),
        (.question, "is this correct"), (.question, "what does this error mean"), (.question, "how long is this"),
        (.question, "does this sound okay"), (.question, "what's the deadline in this"),
        // dictate
        (.dictate, "hi team, the deploy is scheduled for Thursday at ten"), (.dictate, "thanks for the update, see you tomorrow"),
        (.dictate, "can you send me the report by Friday"), (.dictate, "let's meet at the coffee shop near the office"),
        (.dictate, "the function returns a promise that resolves with the user"), (.dictate, "git commit dash m fix typo"),
        (.dictate, "I think we should push the launch to next week"), (.dictate, "please find attached the invoice"),
        (.dictate, "sounds good, I'll take a look"), (.dictate, "new paragraph"), (.dictate, "new line"),
        (.dictate, "the meeting went well and we agreed on the timeline"), (.dictate, "lol that's hilarious"),
        (.dictate, "remind me to call the dentist"), (.dictate, "not sure yet, will confirm tomorrow"),
        (.dictate, "no worries, take your time"), (.dictate, "make sure to bring the charger"),
        (.dictate, "I'm not going to make it tonight"), (.dictate, "what time works for you"),
        (.dictate, "the quarterly numbers look strong"), (.dictate, "cd into the project and run the tests"),
        (.dictate, "first, install the dependencies. second, run the build"), (.dictate, "okay so the idea is"),
        (.dictate, "hey are you around"), (.dictate, "I'll replace the battery this weekend"),
        (.dictate, "we changed the plan to Friday"), (.dictate, "delete the old branch after merging"),
        (.dictate, "kubectl get pods dash n production"), (.dictate, "dear Mr Kothari, thank you for your time"),
        (.dictate, "it was nice meeting you yesterday"), (.dictate, "the weather is nice today"),
    ]

    static let registers: [(Utterance.Register, String)] = [
        (.email, "dear Mr Kothari, thank you for your time"), (.email, "hi team, please find attached the invoice"),
        (.email, "best regards, Aditya"), (.email, "kind regards"), (.email, "following up on my previous email"),
        (.email, "I hope this email finds you well"), (.email, "per our conversation, attached is the proposal"),
        (.email, "thanks in advance, cheers"), (.email, "subject: quarterly review"), (.email, "looking forward to hearing from you"),
        (.chat, "lol that's hilarious"), (.chat, "hey are you around"), (.chat, "brb grabbing coffee"),
        (.chat, "sounds good"), (.chat, "omg yes"), (.chat, "ok cool see you at 5"), (.chat, "haha nice"),
        (.chat, "yo what's up"), (.chat, "k thanks"), (.chat, "can you hop on a call real quick"),
        (.code, "function get user returns a promise"), (.code, "let count equals zero"), (.code, "if the array is empty return null"),
        (.code, "snake case user id"), (.code, "camel case fetch data"), (.code, "import foundation"),
        (.code, "for each item in the list append it"), (.code, "struct transcript span with text string"),
        (.code, "open paren close paren semicolon"), (.code, "const result equals await fetch"),
        (.terminal, "git commit dash m fix typo"), (.terminal, "cd into the project and run the tests"),
        (.terminal, "kubectl get pods dash n production"), (.terminal, "ls dash la"), (.terminal, "sudo apt get install"),
        (.terminal, "npm run build"), (.terminal, "git push origin main"), (.terminal, "cat the log file pipe grep error"),
        (.terminal, "docker compose up dash d"), (.terminal, "rm dash rf node modules"),
        (.list, "first, install the dependencies. second, run the build"), (.list, "bullet one milk bullet two eggs"),
        (.list, "item one item two item three"), (.list, "number one call the bank number two pay rent"),
        (.list, "to do: groceries, laundry, gym"), (.list, "step one open the app step two sign in"),
        (.list, "next item"), (.list, "first of all and secondly and finally"),
        (.prose, "the meeting went well and we agreed on the timeline"), (.prose, "I think we should push the launch to next week"),
        (.prose, "the quarterly numbers look strong"), (.prose, "it was nice meeting you yesterday"),
        (.prose, "the weather is nice today"), (.prose, "she walked into the room and everyone went quiet"),
        (.prose, "our product connects confidence from the acoustic layer through the pipeline"),
        (.prose, "in this chapter we discuss the history of the region"), (.prose, "the report summarises the findings"),
        (.prose, "I remember the first time I saw the ocean"),
    ]

    /// Bundle-ID → register cold-start map. Overridden by `StageContext.register` when set.
    static let bundleRegisters: [String: Utterance.Register] = [
        "com.apple.mail": .email, "com.microsoft.outlook": .email, "com.google.chrome.app.mail": .email,
        "com.tinyspeck.slackmacgap": .chat, "com.hnc.discord": .chat, "com.apple.messages": .chat,
        "com.apple.imessage": .chat, "net.whatsapp.whatsapp": .chat, "us.zoom.xos": .chat, "com.microsoft.teams2": .chat,
        "com.apple.terminal": .terminal, "com.googlecode.iterm2": .terminal, "dev.warp.warp-stable": .terminal,
        "com.github.wez.wezterm": .terminal, "io.alacritty": .terminal, "net.kovidgoyal.kitty": .terminal,
        "com.microsoft.vscode": .code, "com.apple.dt.xcode": .code, "com.jetbrains.intellij": .code,
        "com.todesktop.230313mzl4w4u92": .code, "com.sublimetext.4": .code, "dev.zed.zed": .code,
        "com.apple.notes": .prose, "md.obsidian": .prose, "notion.id": .prose, "com.apple.pages": .prose,
        "com.apple.textedit": .prose, "com.microsoft.word": .prose,
        "com.apple.reminders": .list, "com.culturedcode.thingsmac": .list, "com.omnigroup.omnifocus3": .list,
    ]
}
