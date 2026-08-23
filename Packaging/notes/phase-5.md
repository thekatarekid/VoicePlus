# VoicePlus — Phase 5 (v1.5.0)

"No hotkey at all." Double-tap into hands-free and just talk: a directed-speech gate decides whether you were talking *to the Mac*, a speaker gate ignores everyone who isn't you, and wake verbs ("type …", "send", "<app> …") make the routing reliable while the classifier is young. One gesture hard-mutes everything with a persistent badge — unmute is **never** automatic. Separately, VoicePlus now notices meetings (camera + calendar), offers Join & Record / Record / Ignore from the notch, and produces a diarized ("You"/"Others") transcript + extractive notes **fully locally** — no bot ever joins the call.

**Honest flag note:** the directed-speech ship bar (< 1 false trigger/day) passed only on the synthetic fixture corpus the classifier was tuned against — the spec requires a recorded home+office corpus. `directedSpeech` therefore ships **opt-in experimental, default OFF**; it flips on only after a real-corpus soak holds the bar.

## What's new
- **Directed-speech detection (P5.1, experimental, default off).** Always-on lightweight path: VAD → 10 s RAM-only rolling ring (wiped on mute) → on-device classifier (prosody + content features + context: text field focused, addressed recently). Nothing stored, nothing transmitted. `HandsFreeController` opens the mic for the follow-on utterance only when directed-speech × speaker gate × not-muted all agree.
- **Wake-verb grammar (P5.2).** Hands-free fallback that always works: leading "type/write/dictate …", "send", "<appname> …" parsed by a pre-route (active only in hands-free mode); wake tokens stripped from the landed text with audio ranges/confidence preserved. Hint text prints in the pill for the first 10 uses, then fades.
- **Speaker identification (P5.3).** Onboarding-2 enrollment window: 3 prompted takes through the real engine audio tap → centroid profile (JSON, **no audio persisted**). Non-user speech is ignored in hands-free; TV/podcast audio rejected.
- **Ambient state + hard mute (P5.4).** Three-state glyph (listening / muted / processing) in the menu bar; mute is a **hard latch** — one gesture, persistent MUTED badge, survives relaunch, wins over processing, never auto-released. "Not you" spoken correction (hands-free only, never typed) teaches the classifier and adds speaker-profile negatives.
- **Meeting capture (P5.5).** Camera+calendar signals → meeting detector → notch prompt (Join & Record / Record / Ignore) → local session: mic+system dual capture with AEC, VAD chunking, "You"/"Others" diarization, extractive notes, delivered as a notification post-call. No bot, no upload.

## Install
1. Open the dmg, drag **VoicePlus** to **Applications** (replaces v1.4.0 in place; settings and history preserved).
2. First launch: right-click > **Open** (ad-hoc signed, not notarized).
3. Grant **Microphone**, **Accessibility**, **Input Monitoring**; meeting capture will additionally request **Calendar** and **Screen Recording** (system audio) when first used.
4. Hands-free is off by default: Settings > enable the experimental `directedSpeech` flag, then complete speaker enrollment (3 short takes).

Verify the artifact: `shasum -a 256 VoicePlus_5_1.5.0.dmg` must match `Packaging/releases/CHECKSUMS.txt`
(`bfe33f9b99a243c3d256d82bb2db7b8f7ae062a1197ed807fda5c3a68074a3e0`). `Packaging/verify_install.sh` runs the same check plus a mount/codesign/launch smoke test (passed for this artifact).

## Human test script (must pass before the phase is "done")
| # | Step | Expected | Pass? |
|---|------|----------|-------|
| 1 | Install from this dmg over `VoicePlus_4_1.4.0.dmg` (`verify_install.sh` first) | Mount, codesign, launch OK; state preserved; hands-free is OFF by default — no always-on mic until enabled | [ ] |
| 2 | Enable experimental hands-free; run speaker enrollment (3 takes) | Enrollment window records through the engine tap; profile saved; no WAV of your voice on disk afterwards | [ ] |
| 3 | Hands-free: look at a text field and say "type hello world" | Mic opens without any key; "Hello world" lands; wake-verb hint visible in the pill (first uses) | [ ] |
| 4 | Play a podcast/TV at conversation volume for 10 minutes while working | **Zero** false dictations; glyph may flick to processing but nothing lands (speaker gate + directed gate) | [ ] |
| 5 | Have someone else in the room say "type buy milk" | Rejected — not your voice; nothing lands | [ ] |
| 6 | After a false trigger (if any), say "not you" | Utterance is claimed (never typed); subsequent identical audio no longer triggers | [ ] |
| 7 | One-gesture mute from the menu bar; then relaunch the app | MUTED badge persists across relaunch; nothing is captured while muted; unmute only by explicit gesture | [ ] |
| 8 | Start a video call with a calendar event in the next 15 min | Notch prompt offers Join & Record / Record / Ignore; "Ignore" leaves no trace | [ ] |
| 9 | Record a 5-minute call, then hang up | Notification delivers diarized "You"/"Others" transcript + extractive notes; Data Panel shows **zero** egress for the whole flow | [ ] |
| 10 | Use hands-free for a full workday (soak) | < 1 false trigger over the day (the real-corpus bar); log the count — this gates flipping the flag default | [ ] |
| 11 | Disable the experimental flag | Always-on path fully stops; hotkey dictation unaffected throughout | [ ] |

## Lab numbers (2026-08-24, M2 Pro 16 GB, debug build)
- **Directed-speech harness (synthetic fixture corpus, 12 addressed / 22 ambient clips): 0 false triggers = 0.0/day** simulated at 400 ambient utterances/day (ship bar < 1/day — PASS, but synthetic-only → flag stays experimental/off); missed-address 1/12 = 8.3%, 0/12 after a full "not you" teaching pass.
- **Speaker rejection: 84/84 non-enrolled fixture utterances rejected = 100%** (bar ≥ 99%); own-voice acceptance 31/33 = 93.9% (Gaussian MFCC profile; raw MFCC cosine scored 0% rejection and was discarded).
- Acceptance (`Phase5AcceptanceTests`): directed/flag/mute gating, TV-noise rejection, not-you learning, wake-verb strip, meeting flow with diarized notes + Join&Record URL. Whole package: **952 automated tests green / 0 failed**.

## Known deviations and limitations
- **The directed-speech numbers are from a synthetic (macOS TTS) corpus** the classifier was hand-tuned against. The recorded home+office corpus and a real soak are required before `directedSpeech` can default on — that is why it ships experimental/off.
- **Live always-on capture is untested on hardware** (mic tap, notch prompt, Calendar/Screen-Recording permission strings) — human test script above.
- WeSpeaker embedding path is compiled but untested (no models on disk); the shipping profile is the Gaussian MFCC fallback.
- Meeting notes are extractive (local heuristics) unless a provider is connected; the meeting flow itself never leaves the machine either way.
- Carried: ad-hoc signature, no notarization; `contextBiasing`/`dualPath`/`cloudASR` off; earlier phases' human test scripts pending.
