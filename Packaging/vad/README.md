# Checked-in Silero VAD (V5 C6 + K17)

`silero-vad/silero-vad-unified-256ms-v6.2.1.mlmodelc` — byte-for-byte from
`FluidInference/silero-vad-coreml` (main, 2026-10-01), the file the pinned FluidAudio asks for
(`ModelNames.VAD.sileroVadFile`). 1,063,425 bytes; `voiceplus-manifest.json` records each SHA256.

- **Shipping:** `make_app.sh` → `bundle_models.py --vad` copies it (hash-verified) into
  `VoicePlus.app/Contents/Resources/Models/silero-vad` in every build; `verify_install.sh` checks it.
- **Runtime:** `SileroModelLocator` / `ModelManager.locate(.sileroVAD)` (bundle = external cache).
- **Tests (K17):** resolved from the source checkout, so `SileroVAD.loadIfAvailable()` is non-nil.
- Licence: MIT (Silero Team) — `LICENSE-silero-vad.txt`.

To refresh: download the new `.mlmodelc` into `silero-vad/`, rebuild the manifest, and update
`ModelCatalog` (`requiredPaths`, `approxBytes`) and `bundle_models.py` `VAD`.
