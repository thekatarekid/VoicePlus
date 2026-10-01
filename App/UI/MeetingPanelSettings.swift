import Engine
import Foundation
import Shared
import SwiftUI

// V5 M14 — Settings › Meetings › "During the meeting": "Show my dictations in meeting transcripts"
// (default on). Dictation, a command or a latch note made while a meeting records lands where it
// always lands (§O-c) and is labelled in the meeting transcript ("dictated" / "command" / "note");
// with the switch off, dictated spans are left out of the panel and of the saved transcript, its
// notes and exports. Commands and notes stay labelled either way.

enum MeetingDuringCopy {
    static let section = "During the meeting"
    static let showDictations = "Show my dictations in meeting transcripts"
    static let explanation = "What you dictate, command or note while a meeting records still goes where it always goes. In the meeting transcript it is labelled “dictated”, “command” or “note”; turn this off to leave your dictations out of the transcript and its notes."
}

struct MeetingDuringSettingsSection: View {
    @AppStorage(SettingsKeys.meetingShowDictations) private var showDictations = true

    var body: some View {
        Section(MeetingDuringCopy.section) {
            Toggle(MeetingDuringCopy.showDictations, isOn: $showDictations)
                .accessibilityIdentifier("meetings.settings.showDictations")
                .onChange(of: showDictations) { _, _ in
                    NotificationCenter.default.post(name: MeetingSettings.didChangeNotification, object: nil)
                }
            Text(MeetingDuringCopy.explanation)
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Keeps the live meeting capture's M14 switch in step with Settings.
@MainActor
enum MeetingDictationsWiring {
    private static var observer: NSObjectProtocol?

    static func install(capture: MeetingCaptureController, settings: SettingsStore?, center: NotificationCenter = .default) {
        capture.showsDictations = MeetingCaptureSetup.showsDictations(settings)
        if let observer { center.removeObserver(observer) }
        observer = center.addObserver(forName: MeetingSettings.didChangeNotification, object: nil, queue: .main) { [weak capture] _ in
            MainActor.assumeIsolated {
                capture?.showsDictations = MeetingCaptureSetup.showsDictations(settings)
            }
        }
    }
}
