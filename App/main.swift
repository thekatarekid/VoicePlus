import AppKit
import Shared

// VoicePlusApp entry point: AppKit menu-bar app (LSUIElement via activation policy; see Resources/Info.plist).
enum VoicePlusAppModule {
    static let name = "VoicePlusApp"
}

// Headless soak mode (P1.12 T3): `VoicePlusApp --soak <minutes> [--fixture name]`.
if let soak = SoakRunner.parse(CommandLine.arguments) {
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        let samples = await SoakRunner.run(minutes: soak.minutes, fixture: soak.fixture)
        let worst = samples.map(\.thermal).last(where: { $0 != "nominal" }) ?? "nominal"
        print("soak done: \(samples.last?.dictations ?? 0) dictations, worst thermal=\(worst)")
        done.signal()
    }
    done.wait()
    exit(0)
}

// Headless permission self-test: `VoicePlusApp --request-permission microphone`. Proves against the
// tccd log that the real request API is reached — see PermissionDiagnostics / Packaging/SIGNING.md.
if let permission = PermissionDiagnostics.parseRequestCLI(CommandLine.arguments) {
    exit(PermissionDiagnostics.runRequestCLI(permission))
}

// Headless capture self-test: `VoicePlusApp --mic-selftest [seconds]`. Runs the real AudioPipeline
// through PipelineAudioSource for a few seconds and prints device selection, both node formats,
// AUHAL stream formats, the active acoustic stages, block count and RMS. Must run before
// NSApplication exists, like the other headless modes. See App/Services/MicSelfTest.swift.
if let seconds = MicSelfTest.parseCLI(CommandLine.arguments) {
    exit(MicSelfTest.run(seconds: seconds,
                         deviceUID: MicSelfTest.parseDeviceUID(CommandLine.arguments),
                         voiceProcessing: MicSelfTest.parseVoiceProcessing(CommandLine.arguments)))
}

// Headless TCC entry removal: `VoicePlusApp --reset-permission accessibility`. The same code path
// as the recovery panel's "Remove the old entry" button, so it can be exercised (and its "needs no
// admin rights" claim checked) on a real machine without driving the UI.
if let permission = PermissionDiagnostics.parseResetCLI(CommandLine.arguments) {
    exit(PermissionDiagnostics.runResetCLI(permission))
}

// Headless onboarding-phase self-test: `VoicePlusApp --onboarding-selftest`. Writes the FIX B
// phase line for every permission using the live TCC statuses, so which phase a build actually
// enters can be read straight out of the log instead of inferred.
if CommandLine.arguments.contains("--onboarding-selftest") {
    exit(MainActor.assumeIsolated { OnboardingViewModel.runPhaseSelfTest() })
}

if CommandLine.arguments.contains("--bundled-model-selftest") {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Int32 = 1
    Task.detached { result = await BundledModelSelfTest.run(); done.signal() }
    done.wait()
    exit(result)
}

// V5 M23 — `VoicePlusApp --mcp-stdio`: the meetings MCP server on stdin/stdout, launched by Claude
// Code / Codex. Refuses (exit 2) unless Settings › Providers "Expose meetings to agents" is on.
if MeetingsMCPStdio.requested(CommandLine.arguments) {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Int32 = 1
    Task.detached { result = await MeetingsMCPStdio.run(); done.signal() }
    done.wait()
    exit(result)
}

// T-replay (debug-only, never injects): `VoicePlusApp --replay <wav|dir|stamp|HH:MM:SS|turn-id>
// [--surface kind] [--app bundle-id] [--json out.jsonl]`. See App/Debug/ReplayHarness.swift.
if let replay = ReplayCLI.parse(CommandLine.arguments) {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Int32 = 1
    Task.detached { result = await ReplayCLI.run(replay); done.signal() }
    done.wait()
    exit(result)
}

// T-probe (debug-only, read-only): `VoicePlusApp --ax-probe [--delay s] [--watch s] [--out f.jsonl]
// [--allow-switch]`. Never types; never reads text values. See App/Debug/AXProbe.swift.
if let probe = AXProbeCLI.parse(CommandLine.arguments) {
    exit(AXProbeCLI.run(probe))
}

// Explicit native visual QA; fully isolated from the live capture/insertion composition root.
if CommandLine.arguments.contains("--design-v3-review") {
    let app = NSApplication.shared
    let review = SpoolDesignReview()
    app.delegate = review
    app.setActivationPolicy(.regular)
    app.run()
    exit(0)
}

Log.app.info("VoicePlus starting (Shared \(SharedModule.version))")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
