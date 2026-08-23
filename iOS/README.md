# VoicePlus iOS (P6.5) — keyboard extension + companion app

Not part of the macOS SwiftPM app. The pure logic lives in the SwiftPM target `KeyboardCore`
(`iOS/KeyboardCore`, tests in `Tests/KeyboardCoreTests`) and is built/tested on macOS with the
rest of the package; the UIKit/SwiftUI sources here need Xcode.

```
iOS/
├── project.yml          # XcodeGen spec: VoicePlusMobile (app) + VoicePlusKeyboard (extension)
├── KeyboardCore/        # SwiftPM target (macOS-testable): session state machine, pill model,
│                        #   repair fan-out (pure copy of App/Repair/RepairFanoutModel), persona
│                        #   picker, proxy codec + file mailbox + Darwin doorbell, KeyboardASR protocol
├── Shared/              # compiled into BOTH Xcode targets: SFSpeech on-device ASR, Parakeet slot,
│                        #   App Group store
├── VoicePlusKeyboard/   # KeyboardViewController, PillView (hold-to-talk), FanoutView, PersonaBar
└── VoicePlusMobile/     # companion app: hosts PipelineRunner behind the proxy, edits personas
```

## Build (requires Xcode 15+, not available on the CLT-only build machine)

```sh
brew install xcodegen
cd iOS && xcodegen generate          # → VoicePlusMobile.xcodeproj, resolves ../ as a local package
open VoicePlusMobile.xcodeproj
```

1. Set `DEVELOPMENT_TEAM` in `project.yml` (or the Signing tab) and make sure the App Group
   `group.in.adityakatare.voiceplus` exists for both bundle IDs in your developer account.
2. Run `VoicePlusMobile` on a device (simulator works but has no on-device SFSpeech models).
3. In the app: authorize speech. Then Settings → General → Keyboard → Keyboards → Add New
   Keyboard → VoicePlus → **Allow Full Access** (required for the mic and the App Group).
4. In any text field: hold the pill, talk, release. Low-confidence words fan out as numbered
   chips; tap one (or the word is left as typed). The keyboard returns to the previous keyboard
   automatically after a clean landing (`advanceToNextInputMode`, or `dismissKeyboard` when it is
   the only other keyboard) — no focus dance.

### Package products used
`Shared`, `Pipeline`, `KeyboardCore` — added as library products in the root `Package.swift`.
The root package declares `platforms: [.macOS(.v14)]` only; Xcode builds it for iOS because no
iOS minimum is declared (defaults apply). `Engine` (FluidAudio) is deliberately not linked on iOS.

## How the pieces talk
- ASR: `KeyboardASR` protocol. `ASRSelector` prefers `ParakeetCoreMLASR` when a
  `parakeet-tdt-0.6b.mlmodelc` is bundled (slot only today), else `SpeechRecognizerASR` with
  `requiresOnDeviceRecognition = true`.
- App-proxy: keyboard writes `request.json` into the App Group mailbox and posts a Darwin
  notification; the companion app (when running) runs `PipelineRunner.standard()` with the
  persona text and posts `response.json` + a response notification. The keyboard waits at most
  `KeyboardProxyNames.responseTimeout` (1.5 s) and otherwise lands the raw ASR text.
- Everything the keyboard does is a `KeyboardEffect` produced by `KeyboardSession.handle(_:)`,
  so the whole flow (hold → partials → land → fan-out pick → return) is unit-tested on macOS.

## TestFlight
Archiving, signing with a distribution profile and uploading to TestFlight **require Xcode**
(`xcodebuild -scheme VoicePlusMobile archive` + `xcodebuild -exportArchive` or Xcode Organizer).
This cannot be done from this repo's CLT-only toolchain; the Phase 6 release step for iOS is
therefore manual on a machine with Xcode.

## Untested here
No iOS compile was possible (no Xcode). UIKit sources were written against iOS 17 APIs and
reviewed by hand; expect minor compile fixes on first `xcodegen generate` + build.
