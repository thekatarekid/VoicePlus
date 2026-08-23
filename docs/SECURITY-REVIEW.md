# VoicePlus — Phase 1 security review (P1.12 T5)

Scope: the shipped Phase 1 surfaces as wired by `App/Services/AppContainer.swift`. Method: read
every module's public entry points, grep for process spawning / dynamic loading / secret
handling / network egress, and exercise the injection and focus paths with the chaos tests
(`Tests/AppTests/ChaosTests.swift`, `Tests/InjectionTests/FocusGuardTests.swift`).
Reviewer: P1.12 integration agent, 2026-08-23. Re-run this checklist at every phase gate (§12).

## 1. Text injection surfaces (`Injection/`)

| Surface | Mechanism | Controls |
|---|---|---|
| AX value / selected-text writes | `AXUIElementSetAttributeValue` on the focused element only | Requires Accessibility trust; only the *focused* element of the *frontmost* app; readback verification; never walks to other windows. |
| Synthetic keystrokes | `CGEvent` unicode keystrokes posted **to the target PID** (`postUnicodeKeystrokes(_:toPID:)`), never to the session | Requires Accessibility trust; PID comes from the focus snapshot taken at key release. |
| Paste fallback | `NSPasteboard` write + ⌘V to the target PID, pasteboard restored afterwards | Snapshot/restore of all pasteboard items; change-count check detects a concurrent external write (`ClipboardRestoreTests`). |
| Replace-range (voice repair) | AX selected-range + selected-text write | Bet 4 safety rule: the region must still read *exactly* as what we injected, else untouched (`ReplaceRangeEditor`). |

**Focus guard.** Every request carries the `FocusSnapshot` (pid + bundle ID [+ element token]) taken
at hotkey release. `TextInjector` re-checks before *each* fallback method; a mismatch aborts and
queues the text, which is only re-delivered when that exact app is frontmost again. Chaos tests
flip focus randomly across 30/75 landings and assert no byte reaches the wrong PID.

**Terminals.** `TerminalAdapter` wraps multi-line text in bracketed-paste markers so a shell never
auto-executes a newline; single-line text is typed without a trailing Return. Dictation never
presses Enter in a terminal. (Phase 4 actions will need an explicit confirmation model — out of scope.)

**Spreadsheets / Electron / Figma** adapters only change *how* text is delivered (cell-safe
newlines, ⌥↩), never *where*.

Residual risks: (1) AX writes into password fields — `FocusedElementInfo.role` is available; a
`AXSecureTextField` guard is **not** enforced yet (recommend: refuse injection into secure fields,
Phase 1.5). (2) Dictated text is user speech; we do not sanitise it, by design.

## 2. Subprocess adapters (`Providers/CLIAdapter.swift`)

- Only two known tools (`claude`, `codex`) with fixed argv templates; the prompt is passed as a
  single argv element or on stdin — **never through a shell**, no string interpolation into a
  command line.
- Environment is rebuilt from scratch (`sandboxedEnvironment()`): fixed `PATH`
  (`/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin`), `LANG`, `TERM=dumb`, `NO_COLOR`, `CI=1`,
  plus only `HOME USER TMPDIR SHELL`. No API keys, no tokens, nothing else inherited
  (`stdinPromptRoundTripsAndEnvIsSandboxed` proves a leaked secret in our env is invisible).
- Working directory is a private scratch folder, timeout kills the process, stderr is capped.
- **Fixed in this review:** `CLIDetector` searched every entry of the inherited `PATH`,
  including empty/relative entries (`""`, `.`), so a `claude` file dropped in the app's working
  directory could have been executed with the user's subscription. It now only searches
  absolute directories, de-duplicated, refuses tool names containing `/`, and requires a regular
  executable file (`relativeAndEmptyPathEntriesAreIgnored`).
- Remaining: `/opt/homebrew/bin` is user-writable on every Homebrew Mac; that is the normal
  trust model for CLIs the user installed. We do not verify code signatures of third-party CLIs.
- Prompt-injection: screen context (AX text) and dictated speech end up in prompts sent to
  providers/CLIs. Stages only accept the model's *text* back (`SpanRewriter` refuses to touch
  low-confidence spans and keeps audio ranges); no tool-calling, no actions from provider output.

## 3. Secrets and Keychain (`Providers/SecretStore.swift`, `OAuthPKCE.swift`)

- All API keys and OAuth refresh tokens live in the login Keychain as generic passwords,
  service `in.adityakatare.voiceplus`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
  (never synced, never readable while locked). No plaintext key is ever written to disk, logs,
  or `UserDefaults` (`grep -rn "apiKey\|token" Shared/Database` → none; logs use `.public`
  interpolation only on non-secret fields).
- OAuth uses PKCE (S256) + a random `state` that is verified, with a **loopback-only**
  `NWListener` (`requiredInterfaceType = .loopback`) that captures exactly one redirect and
  stops. No custom URL scheme, so no other app can hijack the callback.
- `InMemorySecretStore` is test-only.
- Onboarding/Settings never display a stored key; "connect what you pay for" writes via
  `SecretStore.set` only.

## 4. No dynamic code loading

`grep -rn "dlopen\|NSClassFromString\|JSContext\|WKWebView\|Bundle(path\|Bundle(url"` across all
modules: **no matches.** No web views (ground rule), no JavaScript, no plug-in loading, no
`Process` other than the CLI adapter above. CoreML models are data loaded through Apple's
compiled-model API; model downloads are SHA256/size-verified where the manifest provides hashes
(`HFDownloader`, `checksumMismatchIsRejected`), and FluidAudio's own fetcher is used only for
its published `.mlmodelc` trees. (Recommendation: pin SHA256 for every `RemoteFile` in
`ModelCatalog` before P1.13 ships — currently only the manifest-fetched models are pinned.)

## 5. Egress gate and Data Panel (`Lab/DataPanel/EgressGate.swift`)

Every byte that can leave the machine goes through one of these paths; each is gated and logged:

| Path | Gate | Log |
|---|---|---|
| Pipeline providers (cloud APIs, ChatGPT subscription, CLI adapters) | `RoutingTable.egressAllowed` → `EgressGate.isAllowed` before any remote provider (added in P1.12) | `DatabaseNetworkLogger` → `network_log` (bytes in/out, host, purpose; failures too) |
| Cloud ASR | behind `cloudASR` flag (default off) and the same table | same |
| Model downloads (Hugging Face) | `ModelManagerTiers.download` checks the kill switch first (added in P1.12) | `EgressGate.log` row per model |
| OAuth sign-in | user-initiated, browser-driven; token exchange over HTTPS | not in the panel (one-off, user-visible); recommend logging in P1.13 |
| Sparkle updates | stubbed (`NoopUpdater`) until P1.13 | — |

Default configuration: no provider pinned, `cloudASR` off, all speech and AX text stay on
device. `DataPanelModel.isClean` is true after a fresh install + dictation session
(`DataPanelTests`). The kill switch is a `UserDefaults` flag read at call time, so flipping it
takes effect on the next request without restart.

Known gap: `FluidAudio`'s internal `DownloadUtils` can fetch models itself if asked directly;
the app only calls it via `ModelManager` (gated), and the Lab's `engine` transcriber only loads
models already on disk.

## 6. Privacy-relevant data at rest

`~/Library/Application Support/VoicePlus/voiceplus.sqlite` (WAL) holds dictation history
(raw + final text), corrections, personas, dictionary, injection outcomes, network log, lab
runs. It is readable by the user only (default `0600` umask under Application Support); no
encryption at rest in Phase 1 — matches the spec (local-first, no account). Audio is **never**
persisted; the capture ring buffer is memory-only and cleared per utterance. Screen context is
AX text only (`LiveAXFocusedWindowText`), capped at 1,500 nodes, never screenshots.

## 7. Checklist for the next review

- [ ] Refuse injection into `AXSecureTextField` / `NSSecureTextField`.
- [ ] Pin SHA256 for every model file in `ModelCatalog`.
- [ ] Log OAuth token exchanges to the Data Panel.
- [ ] Hardened runtime + notarisation (blocked on Developer ID, P1.13 deviation).
- [ ] Phase 2 transform/question routes: provider output must stay text-only (no actions).
