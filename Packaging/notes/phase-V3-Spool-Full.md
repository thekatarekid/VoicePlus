# VoicePlus 1.12.9 — V3 Spool full installer

The native notch now follows the approved V3 design: smaller detailed cassette, shared copper tape material, counterclockwise listening reels, clockwise insertion reels, fixed active height, attached top cap, rounded idle pill, and neutral shadow.

- Two-line transcript scrolls in place; arrows appear only where scrolling is possible.
- Preview lasts 600 ms by default. Reading/editing pauses it; completed edits resume on exit.
- Red alternatives appear beside uncertain words. Edit draft edits inside the notch. Committed corrections learn quietly.
- Held/error drafts support inline correction while retaining explicit delivery controls.
- Tape follows verified destination line geometry and settles into underlines; stale/secure/unverified targets suppress the flourish.
- All three default models are bundled with integrity manifests and upstream license notices. No initial model download is required for the default stack.

## Artifact and validation

- Local artifact: `Packaging/releases/VoicePlus_V3-Spool-Full_1.12.9.dmg`.
- Build: `202609230530`. Size: **714,279,554 bytes**. SHA256: `de94a917dcf1fd1f8e29a82a561f9439290ac39cb21dc9c0b4b733ad64b25a2d`.
- Source branch: `codex/spool-v3-native`.
- The exact 1.12.9 source passes **3,299 integrated tests** in 544.709 seconds. Mounted-artifact checks are recorded in `progress.md` and the V4 Wave 1 build document.
- This is a local release candidate; no GitHub binary release or update-feed publication was performed. Existing appcast and Homebrew download entries remain unchanged.

## Practical limits

- Locally signed, not Developer ID notarized.
- External apps must expose trustworthy text ranges/geometry for decorated suggestions and tape travel. Unsupported fields retain normal insertion and keep review in VoicePlus.
- Bundled-model inference checks use deterministic synthetic audio and establish offline execution, not speech recognition accuracy.

### 1.12.1 follow-up candidate

- Added explicit Finish for menu capture, avoided eager sync Keychain reads on Settings startup, and retained verified Spool through the entire tape flight plus result hold.
- `VoicePlus_V3-Spool-Full_1.12.1.dmg`, 714,962,965 bytes; SHA256 `a6533ab765a7a1317312554848e048eb86484d09e13c53c5c6ae19a591d17248`. Mounted offline model inference, signature/dependency and clean-install verification pass. All 28 earlier installers remain byte-identical.
- Installed native Settings opens promptly without Keychain access. Finish is visible and functional in quiet/menu capture; final preview pauses on pointer hover.
- Full run: 3,266 tests, one onboarding event-ownership race failure; remaining tests passed. Race correction and external TextEdit delivery acceptance are pending; this candidate is not the final verified release.

### 1.12.2 quiet-speech and secure-storage update

- Whisper/normal speech now drives a compressed visual response; maximum native tape displacement is 15% higher. Audio samples, VAD and recognition remain unchanged. 48 focused Spool tests pass.
- Optional provider, connector and sync storage forbids authentication dialogs. Locked storage stays unavailable rather than being overwritten. Guided onboarding event ownership is corrected.
- Self-contained `VoicePlus_V3-Spool-Full_1.12.2.dmg`, build `202609220510`, 714,180,189 bytes. SHA256 `6a2c1b5b96068b8760e210c7106f47ac7981d2750ef1dc148dd676fc4ad89690`. Mounted offline model inference, signature/dependency and clean-install checks pass. All 29 prior installers are byte-identical.
- Installed 1.12.2 via the mounted DMG. Native Settings, Providers and Sync respond without a Keychain prompt; Privacy reports microphone and typing access Allowed. Restored normal recognition after controlled QA; microphone closed.
- External insertion remains unverified: the computer-use focus action selects TextEdit's blank field but macOS identifies Brave as foreground. Controlled attempt ended Cancelled / Nothing inserted; awaiting a manual foreground click. No TextEdit delivery or tape-travel pass claimed. Combined serial regression run: **3,276 tests passed**, 484.832 seconds; the earlier onboarding race no longer fails.

### 1.12.3 verified installer

- Includes the completed V3 implementation, quiet-speech visualization and noninteractive optional secure storage. Corrects Appearance guidance to describe scrolling within the two-line notch.
- `VoicePlus_V3-Spool-Full_1.12.3.dmg`, build `202609220618`, 714,314,380 bytes; SHA256 `e511742ee970026224a6f3a2009c03b79a90fffea976cca2bfc1b531803cac4f`.
- Mounted offline model inference, signature/dependency and clean-install checks pass; 30 earlier installers unchanged. Installed copy and preserved permissions/settings verified natively.
- One-sentence and five-line TextEdit insertions verified; user confirmed ribbon travel and settled underlines. Native scrolling, app Reduce Motion, light/dark and larger text checked. Simulated transcript input was used for delivery tests; this is not microphone recognition-accuracy evidence.
- Latest full suite: 3,276 passes; the subsequent copy-only change passes 46 Settings tests. System VoiceOver/high contrast and external-display acceptance remain unverified. Earlier pending TextEdit records above are historical.

### 1.12.4 keyboard and contrast corrections

- In-notch editing supports Select All, Copy, Cut, Paste, Undo and Redo through the focused native field, with draft-owned undo history. Escape cancels inline edits before the parent turn, preserves composition handling and ignores repeated Carbon presses until release.
- Secondary control boundaries meet at least 3:1 against their fill and pill; Increase Contrast strengthens helper ink, boundaries and scroll thumb. Cassette/tape material is unchanged.
- `VoicePlus_V3-Spool-Full_1.12.4.dmg`, build `202609220651`, **714,314,563 bytes**; SHA256 `e534eebd7f30f294e20c9d0f056fad8d725afc38e3d371a1ce1f09a71da9bf67`. Mounted offline model inference, clean-install, signature/dependency and installability checks pass. All 31 earlier installers remain byte-identical. Installed app retains normal recognition and original preview settings.
- **3,288 tests passed** in the complete integrated run (679.292 s). Native Cmd+A/replacement, Undo/Redo, Escape-to-original-preview and Cmd+Return pass; test cancelled with nothing inserted. High-contrast unit resolution is not system-toggle visual evidence. VoiceOver, complete keyboard traversal/physical global Escape, system high contrast and external-display acceptance remain unverified.

### 1.12.5–1.12.7 diagnostic and keyboard follow-up

- 1.12.5 exposed an explicit ad-hoc signing branch error and was rejected without installation. It remains only as provenance and must not be distributed.
- 1.12.6 corrected signing selection and diagnostic targeting. All 26 native state presentations were captured across the installed review passes.
- 1.12.7 fixes native text-only keyboard traversal through the transcript, scroll rail, applicable arrows and every footer action while preserving the V3 artwork and layout. Installed Tab/Shift-Tab, scrolling, Edit draft activation and inline-editor Escape pass.
- The 1.12.7 DMG passes UDIF integrity, app/DMG signature checks, clean copied-install checks, portable dependency checks, model manifest/license validation and actual offline TDT, EOU and speaker inference from mounted resources. The installed copy has the same CDHash as the mounted app.
- This build is ad-hoc signed and unnotarized. It is a verified local self-contained installer, not a public Gatekeeper-ready release; appcast and Homebrew metadata remain unchanged.

### 1.12.9 final fidelity follow-up

- Active dictation turns remain pinned to the display where they began. If that display disappears, VoicePlus moves a recovery surface to an available display, retains the transcript and requires an explicit **Insert here** revalidation before delivery.
- Runtime and diagnostic copy now use the V3 language, including **Hands-free · listening**, **Finish dictation**, **Couldn’t confirm insertion**, **Check destination** and **Review inserted text**.
- The transcript scroll rail exposes direction, range, value and the transcript it controls to accessibility clients. The obsolete V1 **Review All** flow and its unused expanded-review surface were removed.
- Native inspection on installed 1.12.9 confirmed the new hands-free and unconfirmed states, inline red suggestion copy, and bidirectional long-text scrolling. The rail moved from 100% to 83% and exposed both scroll directions; review mode then exited and the normal green idle chip returned.
- The first local 1.12.8 packaging attempt was rejected and deleted because it omitted the required full-installer model flags. It was never installed, published or recorded as a valid release. The replacement 1.12.9 DMG contains 688 MB of verified models and passes read-only mounted TDT, EOU and speaker inference, clean-copy launch, signature, permission-description, dependency, quarantine and writability checks.
- Public appcast and Homebrew metadata remain unchanged. The verified DMG is local and excluded from Git because it exceeds GitHub's 100 MB file limit.
