# Sync (P6.4) — encrypted, serverless profile sync

- `SyncPayload`: dictionary, personas, snippets, adapter weight blobs, settings. Per-record `version`/`updatedAt`/`deleted`. **Never audio** — `SyncPayload.audit()` reflects over the shape and rejects audio-ish fields/types; `SyncEngine.push` asserts it.
- `SyncKey`: 256-bit ChaChaPoly key. Derived via HKDF-SHA256 from an X25519 pairing secret (`PairingSession`) or a passphrase (`ExportBundle`). Persisted only through `SyncKeyStore` (Keychain in prod, in-memory in tests).
- `PairingPayload` ⇄ QR string (`voiceplus-pair://v1?...`); `QRCode.image(for:)` renders via CIQRCodeGenerator.
- `SyncMerge`: last-writer-wins per record (updatedAt, then version, then local).
- `SyncTransport`: blob-per-device; `InMemorySyncTransport`, `DirectorySyncTransport` (iCloud Drive / any synced folder).
- `ExportBundle`: `.voiceplus` encrypted export/import.
