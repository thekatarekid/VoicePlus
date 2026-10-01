import SwiftUI
import Engine
import Foundation

/// S8 — what Ready offers besides its verdict (design §8.7): the one fix for each blocker, and the
/// optional steps that come later ("Meeting/system-audio and Calendar are optional later steps").
/// Pure, so the routing is testable without a window.
public enum OnboardingReady {
    /// Where a Ready blocker's recovery action goes.
    public enum Fix: Equatable, Sendable {
        /// The permission's own System Settings pane.
        case systemSettings(OnboardingPermission)
        /// Install (or retry installing) the speech model from right here.
        case installModels
        /// "Retry loading" (M07).
        case retryModelLoad
        /// Settings › Models (the catalogue's "Open Models").
        case models
        /// A section of the main window.
        case section(MainWindowSection)
    }

    /// The catalogue action for `id`, as a destination. Each entry's action title (design §10) names
    /// the same place: P01 "Open Microphone settings", M01 "Open Models", A05 "Test microphone"…
    public static func fix(for id: RecoveryID) -> Fix {
        switch id {
        case .P01: return .systemSettings(.microphone)
        case .P02: return .systemSettings(.accessibility)
        case .M02: return .installModels
        case .M07: return .retryModelLoad
        case .M01: return .models
        // A03 "Choose microphone", A05 "Test microphone", X03 "Try voice setup again": the Voice
        // section holds the input selector, the test and enrollment (design §8.4).
        default: return .section(.voice)
        }
    }

    /// One optional later step, shown on Ready and never asked for during setup.
    public struct LaterItem: Equatable, Sendable, Identifiable {
        public var id: String { title }
        public let title: String
        public let detail: String
        public let action: String
        public let section: MainWindowSection
    }

    public static let laterHeading = "Optional, later"

    /// Meetings (microphone plus system audio) and Calendar. Neither permission is requested here:
    /// both are asked for in Meetings, when they are first needed.
    public static let laterItems: [LaterItem] = [
        LaterItem(title: "Meeting notes and system audio",
                  detail: "Record a meeting from your microphone and, if you allow it, the other side of the call.",
                  action: "Open Meetings", section: .meetings),
        LaterItem(title: "Calendar",
                  detail: "Calendar connection is optional. Recording a meeting never needs it.",
                  action: "Open Meetings", section: .meetings),
    ]
}

// MARK: - I1 · What to expect (first run)

/// I1 — the Ready step's "What to expect" card: four plain facts so the first dictations match the
/// user's expectations. Copy lives with `OnboardingCopy`; the voice-fix examples are real phrases the
/// repair grammar accepts (`RepairGrammar.parse`), and the tests hold them to that.
public extension OnboardingCopy {
    struct ExpectationItem: Equatable, Sendable, Identifiable {
        public var id: String
        public let symbol: String
        public let title: String
        public let detail: String
    }

    static let expectHeading = "What to expect"

    /// Said after a dictation lands, these undo or correct it. Each must parse as a repair.
    static let expectVoiceFixExamples = ["scratch that", "no, Kothari", "put it back"]

    static let expectItems: [ExpectationItem] = [
        ExpectationItem(id: "local", symbol: "lock.laptopcomputer", title: "Runs on this Mac",
                        detail: "Speech is turned into text by a model on this Mac. Your voice is not sent anywhere to do it, "
                            + "and dictation works offline."),
        ExpectationItem(id: "english", symbol: "character.bubble", title: "English first",
                        detail: "VoicePlus is tuned for English. Other languages and mixed-language speech may come out "
                            + "less accurate for now."),
        ExpectationItem(id: "names", symbol: "person.text.rectangle", title: "Names get better with your Dictionary",
                        detail: "Unusual names and terms can be misheard at first. Add them to Dictionary, or correct "
                            + "them once, and VoicePlus spells them your way after that."),
        ExpectationItem(id: "fix", symbol: "arrow.uturn.backward", title: "Fix it by voice",
                        detail: "Right after a dictation, say “scratch that” to remove it, “no, Kothari” to correct "
                            + "a word, or “put it back” to undo the fix."),
    ]

    static let expectDictionaryAction = "Open Dictionary"
}

public extension OnboardingReady {
    /// Where the card's one action goes.
    static let expectDictionarySection: MainWindowSection = .dictionary
}

/// I1 — the card itself, shown on Ready above the optional later steps.
struct OnboardingWhatToExpectCard: View {
    var openDictionary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(OnboardingCopy.expectHeading).font(.headline)
            ForEach(OnboardingCopy.expectItems) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: item.symbol).foregroundStyle(.secondary).frame(width: 18)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.callout.weight(.semibold))
                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("onboarding.expect.\(item.id)")
            }
            Button(OnboardingCopy.expectDictionaryAction, action: openDictionary).font(.caption)
                .accessibilityIdentifier("onboarding.expect.dictionary")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("onboarding.expect")
    }
}
