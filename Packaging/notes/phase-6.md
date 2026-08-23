# VoicePlus — Phase 6 (v1.6.0)

"It sounds like you." VoicePlus now learns from you, on-device: every correction and post-dictation edit becomes training data, a periodic retrain feeds a learned lexicon back into recognition, and the Lab's new "you" tab proves the claim — day-30 personal WER lower than day-1. Speak Hindi and English in one breath and it lands as one mixed-script string with an `EN·हि` badge — no language toggle exists. Your whole profile (dictionary, personas, snippets, learned weights, settings — **never audio**) syncs end-to-end encrypted between machines via QR pairing, and exports to a single `.voiceplus` file.

## What's new
- **Personal adaptation loop (P6.1).** Repair-event corrections and post-dictation edits (the zero-edit tracker now carries original/final text, word-diffed to word-level variants) accumulate as paired training data on device → periodic bias-list retrain (LoRA fine-tune measured infeasible on-device with CoreML inference-only graphs — the Lab decided, as the plan allowed) → learned lexicon feeds the biasing harvester + a regression-guard stage in the live pipeline. Personal WER tracked per day in the Lab **"you"** tab (day-by-day table + day-1-vs-latest trend).
- **Learned lexicon / "Train by voice" (P6.2).** Say the word once in dictionary settings (recorded through the engine tap); one-time "I'll remember *Kothari*" toast — never repeats for the same word; the original text is kept as an alternate so repair can always back out.
- **Code-switching (P6.3).** Streaming language detection (script + romanized-Hindi n-grams) → script-aware merge into **one** mixed Devanagari+Latin string with correct spacing/punctuation; pill script indicator `EN` / `हि` / `EN·हि` with hysteresis. **No language toggle.** Indic RNNT weights are not shipped — see limitations.
- **Encrypted sync (P6.4).** Sync payload = dictionary + personas + snippets + learned weights + settings, **never audio** (payload audited in tests); end-to-end encrypted (ChaChaPoly, HKDF, user-held key in Keychain); X25519 QR pairing (Settings > Sync shows the QR); folder transport (any synced folder, e.g. iCloud Drive); export/import-everything `.voiceplus` file; last-writer-wins per record.
- **iOS keyboard (P6.5) — source only.** Hold-to-talk keyboard extension (KeyboardCore state machine, repair fan-out, personas, app-proxy mailbox) is built and unit-tested (22 tests) with an XcodeGen project tree, but **no Xcode/iOS SDK exists on the build machine** — no TestFlight build ships with this release; archive is a manual step on an Xcode machine.

## Install
1. Open the dmg, drag **VoicePlus** to **Applications** (replaces v1.5.0 in place; settings, history and profile preserved).
2. First launch: right-click > **Open** (ad-hoc signed, not notarized).
3. Grant **Microphone**, **Accessibility**, **Input Monitoring** if newly prompted.
4. Optional: Settings > Sync to pair a second Mac (scan the QR) or export your profile; Settings > Dictionary for "Train by voice".

Verify the artifact: `shasum -a 256 VoicePlus_6_1.6.0.dmg` must match `Packaging/releases/CHECKSUMS.txt`
(`66ae1e52b469a2b65a85761f16e5256865d7e707eed5bc68ae9ee1305310a1af`). `Packaging/verify_install.sh` runs the same check plus a mount/codesign/launch smoke test (passed for this artifact).

## Human test script (must pass before the phase is "done")
| # | Step | Expected | Pass? |
|---|------|----------|-------|
| 1 | Install from this dmg over `VoicePlus_5_1.5.0.dmg` (`verify_install.sh` first) | Mount, codesign, launch OK; profile/history preserved | [ ] |
| 2 | Dictate a name it gets wrong (e.g. "Kothari"); fix it via repair or by editing the landed text | Correction is captured (Lab "you" tab pair count increments); no audio appears under app data except the training clip store | [ ] |
| 3 | After the next retrain tick, dictate the same name again | It lands correctly — the corrected word is never re-mis-heard | [ ] |
| 4 | Dictionary settings > "Train by voice" for a second word | One-time "I'll remember …" toast; training the same word again shows **no** toast | [ ] |
| 5 | Say a Hinglish sentence in one breath ("kal meeting hai, send the deck tomorrow") | Lands as **one** string, Devanagari + Latin correctly interleaved; pill badge reads `EN·हि`; no toggle anywhere in the UI | [ ] |
| 6 | Open Lab > "you" tab after a few days of use | Day-by-day personal WER table renders; day-30 (or latest) < day-1 trend visible | [ ] |
| 7 | Settings > Sync on Mac A: show QR; scan from Mac B | Both ends derive the same key (pairing succeeds); profile appears on Mac B; edit a snippet on B → syncs back to A (LWW) | [ ] |
| 8 | Export everything to a `.voiceplus` file; import on a clean install with the passphrase | Full profile restored; wrong passphrase is **rejected** with no partial import | [ ] |
| 9 | Inspect the sync payload/export (Data Panel + file) | No audio, no raw clips — dictionary/personas/snippets/weights/settings only; zero network egress with folder transport on local disk | [ ] |
| 10 | Regression: hotkey dictation, transform on selection, Right ⌘ action, hard mute | All previous-phase behaviours intact after the adaptation stages joined the pipeline | [ ] |
| 11 | Quit and relaunch | Learned lexicon persists (lexicon.json); pill badge state resets cleanly; no crash log | [ ] |

## Lab numbers (2026-08-24, M2 Pro 16 GB, debug build)
- **Day-30 < day-1 personal WER** proven through the *wired* loop (synthetic replay in `Phase6AcceptanceTests`); regression fixture: **corrected word never re-mis-heard**.
- **Hinglish single-breath fixture lands as one mixed-script string** with the `EN·हि` badge (23 CodeSwitch tests + acceptance).
- **Sync round-trip:** profile export→import restores everything; wrong-passphrase rejected; **QR pairing derives one shared key on both ends**; folder-transport merge is LWW-correct; payload audited: no audio.
- Whole package at this tag: **959 automated tests green / 0 failed** (the full 7-phase suite).

## Known deviations and limitations
- **Indic RNNT weights are not shipped.** IndicConformer-600m is MIT-verified but has no official CoreML export; `CodeSwitchRouter` runs with an `UnavailableIndicBackend` that reports *why* routing fell back — the merger/indicator/injection path works with the primary recognizer today, and Devanagari output quality is bounded by it until a backend lands.
- **iOS keyboard is source-only in this release** — no Xcode on the build machine means the UIKit/extension tree is uncompiled and there is no TestFlight build; expect minor fixes on first `xcodegen` build. Mac→iPhone QR round-trip is therefore untested end-to-end (Mac→Mac is covered).
- LoRA-style on-device fine-tune is infeasible with CoreML inference-only graphs; the shipping learner is the saturating bias-list (the code seam for a future adapter remains).
- Keychain on real hardware and the iCloud-folder transport are untested live; the day-30 curve on *real* usage accrues only with real use.
- Carried: ad-hoc signature, no notarization, no hardened runtime; `contextBiasing`/`dualPath`/`cloudASR`/`directedSpeech` off by default; human test scripts for phases 1–5 pending on a clean account.
