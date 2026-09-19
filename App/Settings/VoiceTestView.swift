import Engine
import SwiftUI

// S7e — the microphone test as drawn under Voice › Input quality: Spool, the real level meter, the
// test sentence, and the phase's words (`VoiceTestPresentation`). Nothing here decides a state.

/// Spool on a Voice surface (design §8.9, S12 `SpoolSurfacePolicy`): still at rest, moving only
/// while real capture is open, parked (still `finishing`) while analysing, and in the catalogue's
/// still pose beside a recovery. The tape follows the real capture level and nothing else.
struct VoiceSpoolStrip: View {
    var surface: SpoolSurfacePolicy.Surface
    var activity: SpoolSurfacePolicy.Activity
    var since: Date
    var level: Double
    var recovery: RecoveryID?

    /// The pill scene at a third of its height: tape lane on the left, the character on the right.
    static let size = CGSize(width: 176, height: 52)

    /// What is drawn, as data.
    static func appearance(surface: SpoolSurfacePolicy.Surface, activity: SpoolSurfacePolicy.Activity,
                           recovery: RecoveryID?) -> SpoolSurfacePolicy.Appearance {
        let base = SpoolSurfacePolicy.appearance(on: surface, activity: activity)
            ?? SpoolSurfacePolicy.Appearance(key: .ready, animates: false)
        guard let recovery, !base.animates else { return base }
        return SpoolSurfacePolicy.Appearance(key: SpoolSurfacePolicy.cameo(for: recovery), animates: false)
    }

    var body: some View {
        let appearance = Self.appearance(surface: surface, activity: activity, recovery: recovery)
        SpoolView(key: appearance.key, stateStartedAt: since, level: appearance.animates ? level : 0,
                  style: .pill, reduceMotion: appearance.animates ? nil : true)
            .frame(width: Self.size.width, height: Self.size.height)
            .accessibilityHidden(true)
    }
}

/// The prototype's `.test-meter`: sixteen bars of the last sixteen real levels. Flat when the
/// microphone is closed — never illustrated.
struct VoiceLevelMeter: View {
    var levels: [Double]
    var live: Bool

    static let barWidth: CGFloat = 5
    static let maximumHeight: CGFloat = 44
    static let minimumHeight: CGFloat = 3

    var body: some View {
        HStack(alignment: .center, spacing: Tokens.Spacing.xs) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(live ? WindowColor.accent : WindowColor.separator)
                    .frame(width: Self.barWidth,
                           height: max(Self.minimumHeight, CGFloat(level) * Self.maximumHeight))
            }
        }
        .frame(height: Self.maximumHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Input level")
        .accessibilityValue(live ? "\(Int(((levels.last ?? 0) * 100).rounded())) percent" : "Microphone closed")
        .accessibilityIdentifier("voice.test.meter")
    }
}

/// Spool, meter, sentence and the phase's words.
struct VoiceTestPanel: View {
    @ObservedObject var test: VoiceMicrophoneTest
    var presentation: VoiceTestPresentation
    var perform: (VoiceTestAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            HStack(alignment: .center, spacing: Tokens.Spacing.l) {
                VoiceSpoolStrip(surface: .voiceTest, activity: test.phase.activity, since: test.phaseStartedAt,
                                level: test.level, recovery: presentation.recoveryID)
                VoiceLevelMeter(levels: test.meter, live: test.phase.isCapturing)
                Spacer(minLength: 0)
            }
            Text(presentation.meterLabel)
                .windowFont(Tokens.Typography.meta)
                .foregroundStyle(WindowColor.secondaryInk)
                .accessibilityIdentifier("voice.test.meterLabel")
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text(VoiceTestCopy.sentenceEyebrow.uppercased())
                    .windowFont(Tokens.Typography.key)
                    .foregroundStyle(WindowColor.secondaryInk)
                Text("“\(VoiceMicrophoneTest.sentence)”")
                    .windowFont(Tokens.Typography.body)
                    .foregroundStyle(WindowColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(Tokens.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Tokens.Radius.control).fill(WindowColor.surface))
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                HStack(spacing: Tokens.Spacing.s) {
                    if let tag = presentation.tag {
                        StatusTag(tag.text, kind: tag.good ? .good : .warn)
                    } else if presentation.recoveryID != nil {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(WindowColor.attention)
                    }
                    Text(presentation.status)
                        .windowFont(Tokens.Typography.body)
                        .fontWeight(.medium)
                        .foregroundStyle(presentation.recoveryID == nil ? WindowColor.ink : WindowColor.attention)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("voice.test.status")
                }
                if let detail = presentation.detail {
                    Text(detail)
                        .windowFont(Tokens.Typography.meta)
                        .foregroundStyle(WindowColor.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let hold = presentation.holdNote {
                    Text(hold)
                        .windowFont(Tokens.Typography.meta)
                        .foregroundStyle(WindowColor.secondaryInk)
                }
            }
            .accessibilityElement(children: .combine)
            if let secondary = presentation.secondary {
                Button(secondary.title) { perform(secondary.action) }
                    .buttonStyle(.bordered)
                    .disabled(!secondary.isEnabled)
                    .accessibilityIdentifier("voice.test.recovery")
            }
        }
        .padding(Tokens.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.group, style: .continuous)
            .strokeBorder(WindowColor.separator, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice.test")
    }
}

/// The Input quality row's button: Test microphone / Stop / Test again / the catalogue's retry.
struct VoiceTestButton: View {
    var button: VoiceTestPresentation.Button
    var perform: (VoiceTestAction) -> Void

    var body: some View {
        Button(button.title) { perform(button.action) }
            .buttonStyle(.borderedProminent)
            .tint(button.action == .stop ? WindowColor.attention : WindowColor.accent)
            .disabled(!button.isEnabled)
            .accessibilityIdentifier(button.action == .stop ? "voice.test.stop" : "voice.test.start")
    }
}
