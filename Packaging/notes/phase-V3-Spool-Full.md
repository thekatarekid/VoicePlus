# VoicePlus 1.12.0 — V3 Spool full installer

The native notch now follows the approved V3 design: smaller detailed cassette, shared copper tape material, counterclockwise listening reels, clockwise insertion reels, fixed active height, attached top cap, rounded idle pill, and neutral shadow.

- Two-line transcript scrolls in place; arrows appear only where scrolling is possible.
- Preview lasts 600 ms by default. Reading/editing pauses it; completed edits resume on exit.
- Red alternatives appear beside uncertain words. Edit draft edits inside the notch. Committed corrections learn quietly.
- Held/error drafts support inline correction while retaining explicit delivery controls.
- Tape follows verified destination line geometry and settles into underlines; stale/secure/unverified targets suppress the flourish.
- All three default models are bundled with integrity manifests and upstream license notices. No initial model download is required for the default stack.

## Artifact and validation

- Local artifact: `Packaging/releases/VoicePlus_V3-Spool-Full_1.12.0.dmg`.
- Build: `202609200651`. SHA256 is recorded in `Packaging/releases/CHECKSUMS.txt`.
- Source branch: `codex/spool-v3-native`.
- Final test count and mounted-artifact checks are recorded in `progress.md` and the V4 Wave 1 build document.
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
