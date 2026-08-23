# VoicePlus — Phase 1 (v1.0.0)

"You never touch the keyboard to fix it." First dmg. Everything runs on device by default; nothing leaves the machine unless you connect a provider yourself.

## What's new
- **Menu-bar app + pill.** Notch-aware pill shows listening / preview / landed state; launch-at-login; no Dock icon.
- **Hold-to-talk hotkey.** Hotkey state machine with focus snapshot taken at key release, so text only ever lands in the app you were in.
- **On-device ASR.** Parakeet TDT 0.6B v3 via FluidAudio (CoreML/ANE) with streaming EOU previews; Apple Speech as automatic fallback when no model is on disk. Model tiers (Fast / Balanced / Best) download in the background with SHA256 verification and resume.
- **Audio front end.** HAL/AVAudioEngine capture, 16 kHz converter, Apple voice-processing AEC, spectral-gate noise suppression, energy VAD (Silero slot), endpointer, Bluetooth pre-roll, mic-quality meter.
- **Pipeline.** Gatekeeper (rules + naive Bayes) routes dictate / repair / command; five deterministic formatters (prose+lists, email, chat, code, terminal) chosen by the frontmost app's register; style stage learns per-app capitalization and terminal-period habits. Confidence contract enforced at every stage (Bet 9: low-confidence spans are never rewritten).
- **Voice repair.** "no, <word>" / "undo" grammar over the last utterance; alternates from beam + Double Metaphone enrichment over your dictionary and screen vocabulary; fan-out panel; replace-range edits verified against what was actually injected.
- **Injection stack.** AX value/selected-text write → per-PID unicode keystrokes → paste with clipboard save/restore; app adapters for terminals (bracketed paste, never presses Return), spreadsheets, Electron apps, Figma; focus guard aborts and re-queues on focus change.
- **Providers (all optional, all off by default).** Ollama, LM Studio, any OpenAI-compatible endpoint (OpenAI / OpenRouter / Anthropic / Groq / Cerebras / custom), ChatGPT subscription via OAuth PKCE, and `claude` / `codex` CLI adapters in a sandboxed environment. Keys live in the Keychain only.
- **Lab + Zero-edit counter + Data Panel.** In-app and CLI harness scoring WER / entity recall / latency / zero-edit prediction over fixture suites; daily zero-edit trend; Data Panel lists every byte of network egress with a kill switch.
- **Onboarding + Settings.** Permission flow with denied branches, mic meter, model choice, guided first dictation; Settings for hotkey, per-stage routing, personas, dictionary, feature flags, Data Panel.

## Install
1. Open the dmg, drag **VoicePlus** to **Applications**.
2. First launch: right-click > **Open** (build is ad-hoc signed, not notarized — Gatekeeper will warn once).
3. Grant **Microphone** and **Accessibility** when prompted. **Input Monitoring** is requested for the global hotkey. Contacts is optional (name biasing).
4. Pick a model tier; Apple Speech works immediately while the download runs.

Verify the artifact: `shasum -a 256 VoicePlus_1_1.0.0.dmg` must match `Packaging/releases/CHECKSUMS.txt`
(`6ce21d6cecb061bbc18308c28ffbb4d7a0fe236f19a7fa0edef116cc6620e0f9`). `Packaging/verify_install.sh` runs the same check plus a mount/codesign/launch smoke test.

## Human test script (must pass before the phase is "done")
| # | Step | Expected | Pass? |
|---|------|----------|-------|
| 1 | Fresh install from this dmg on a clean user account (`verify_install.sh` first) | Mount, codesign `--verify` and launch all OK; app icon in the menu bar within 5s | [ ] |
| 2 | First launch via right-click > Open | Gatekeeper warning accepted once; onboarding window appears | [ ] |
| 3 | Walk onboarding: deny Microphone first, then grant | Denied branch explains and links to System Settings; continues after grant; no dead end | [ ] |
| 4 | Grant Accessibility + Input Monitoring, choose "Balanced" model | Pill shows download progress; dictation works via Apple Speech meanwhile | [ ] |
| 5 | Hold hotkey, say "hello world, this is a test" into TextEdit | Preview in pill while speaking; "Hello world, this is a test." lands at the cursor ≤ 700ms after release | [ ] |
| 6 | Same phrase into Slack (or Messages) and a Terminal prompt | Slack: chat register, light punctuation. Terminal: verbatim, no trailing Return, nothing executed | [ ] |
| 7 | Dictate "send it to Maria", then hold hotkey and say "no, Mariah" | Only the last word is replaced; surrounding text untouched; correction logged in history | [ ] |
| 8 | Dictate into Mail, Notes, a browser text field | Text lands in each; clipboard contents unchanged afterwards | [ ] |
| 9 | Switch apps mid-dictation (⌘-Tab before key release) | Nothing typed into the new app; text queued and delivered when the original app is frontmost again | [ ] |
| 10 | Open Lab, run the `clean` suite against the engine | Run completes; WER ≈ 3–4%, per-item p50 < 1 s; report saved | [ ] |
| 11 | Open Data Panel after steps 5–10 | Only model-download rows (if any); pipeline egress 0 bytes; "clean" status | [ ] |
| 12 | Settings > Flags | `voiceRepair` on, `contextBiasing` off, `dualPath` off, `cloudASR` off; toggling persists across relaunch | [ ] |
| 13 | Upgrade in place over `VoicePlus_0_0.0.1.dmg` | Settings + history preserved; no re-prompt for permissions | [ ] |
| 14 | Quit and relaunch | Previous state restored, no crash log in Console | [ ] |

## Lab numbers (DECISIONS.md, 2026-08-23, M2 Pro 16 GB, debug build — upper bounds)
- Golden test, 12 clean fixtures, Parakeet TDT v3: **mean WER 2.9%**, max final-pass latency 146 ms (3–5 s utterances); EOU preview WER 7.7%.
- Lab harness, all five suites (61 items, TTS audio): **overall WER 13.3%**, entity recall 50%, p50/p95 525/610 ms incl. pipeline and first-item prewarm. Per suite: clean 3.5%, noisy 9.7%, entity 20.8%, technical 30.9%, commands 3.4%.
- End-to-end latency budget test (10 s / 30-span utterance, mock engine, 20 runs): **p50 53 ms, p95 53 ms**, pipeline-only 52 ms (budget 700 / 1200 / 250). Expected ≈ 250 ms p50 on hardware with the real final pass + AX write.
- Voice repair: truth in top-3 alternates 26/30 (87%) on the synthetic mangled set; grammar routing 80/80.
- Soak (3 min, saturated mock loop, 57k dictations): thermal nominal throughout, landing p50 flat at ~3 ms, RSS +4.5 KB/dictation (in-memory history).
- 613 automated tests green.

## Known deviations and limitations
- **Ad-hoc code signature; no notarization; no hardened runtime** (no Developer ID identity). Sparkle appcast unsigned (no EdDSA key); in-app updates are stubbed (`NoopUpdater`).
- **`contextBiasing` defaults off.** On the real decoder the only hook is a post-hoc rescorer over greedy TDT output; entity recall did not move (31.6% → 31.6%), so the kill criterion applies. The synthetic in-loop decoder shows +200% recall, so the path stays and flips back when the decoder fork exposes per-step logits (Phase 1.5).
- **`dualPath` (Bet 4) off** — reconciler built, not wired to UX (Phase 1.5).
- **Silero VAD falls back to energy VAD** (needs model v6.2.1 on disk); energy VAD F1 0.983 on fixtures.
- **Fixtures are synthetic** (macOS `say` TTS); entity/technical numbers are upper bounds and no real-world suites are recorded yet (`Lab/FIXTURES.md`). Repair alternates' live top-3 hit rate on human speech is unmeasured.
- **Not verified on hardware:** live mic → injection latency, the 2 h fanless soak (only a 3 min mock soak was run; `Packaging/soak.sh 120` is ready), the 12-app injection matrix beyond mock level, real TCC prompts.
- **CI unverified** (`.github/workflows/ci.yml` targets macos-14 + Xcode 16.2; never executed from this machine). Local toolchain is CLT-only with a patched shim, Swift Testing only.
- **Security review follow-ups** (docs/SECURITY-REVIEW.md): injection into secure text fields is not yet refused; not every `ModelCatalog` file has a pinned SHA256; OAuth token exchange is not logged to the Data Panel; third-party CLI code signatures are not checked. History DB is unencrypted at rest (user-only permissions); audio is never persisted.
- Whisper is catalog-only; no MLX/CoreML local LLM providers; cloud ASR slot exists but is off.
