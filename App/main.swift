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

Log.app.info("VoicePlus starting (Shared \(SharedModule.version))")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
