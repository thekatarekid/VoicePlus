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
