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
