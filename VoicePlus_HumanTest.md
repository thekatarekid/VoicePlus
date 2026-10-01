# VoicePlus — Human Test Plan (V5)

Item **T1** of `VoicePlus_Improvements_V5_Build.md`. This is the one document the owner runs on real
Macs to verify everything the automated suites cannot: real permissions (TCC), real microphones and
AirPods, real destination apps, real displays, real models and real meetings. It is testing, not data
collection (V5 rule 0.2): nothing here asks you to record a dataset.

Written 2026-10-02 against `main` after the W5–W7 gate and the W8 follow-ups (J5 updater, J2 CI,
I4 audit, Q13/HW3/D5/O1/N2/LANG1/K21/M-d fixes). Every case can be run without reading code.

---

## 0. How to run this document

### 0.1 Machines and accounts
| Rig | Use for | Required |
|---|---|---|
| **R1** — the owner's Mac, notched built-in display, 16 GB | Almost everything | Yes |
| **R2** — an external monitor (and, for Q6/Q7, one AirPlay or second display) attached to R1 | Placement, Q6/Q7, accessibility | Yes |
| **R3** — a clean macOS user account on R1 (System Settings › Users & Groups › Add User) | Fresh install, onboarding, permissions from zero | Yes |
| **R4** — an 8 GB Mac and a ≥ 24 GB Mac | HW1/HW2 memory tiers, CU8 model size by RAM | If available; else mark "not run" |
| **R5** — a Mac without a notch (or an external display only, lid closed) | No-notch placement | If available |
| AirPods (any model with a mic) + a wired/USB mic | Conditions, K16, C3, K5 | Yes |
| A second person (2–3 ft away) and a TV/YouTube video with speech | Conditions, K2/K4, L-series | Yes |
| A Zoom/Meet/Teams call with one or two other people | Meetings | Yes |

### 0.2 Build under test
- Install the V5 candidate DMG produced by `Packaging/release.sh <phase> <version>` (ad-hoc signed; J4
  notarization is an owner action — see §1). Record the version from Settings › Updates (`settings.version`).
- Before the first run: complete owner action **OA-01** (Q16 stale LaunchServices record) once.

### 0.3 Evidence — what to capture, where it lives
| Evidence | How |
|---|---|
| **Screenshot** | ⌘⇧4 (region) or ⌘⇧5 (window). Name it `<case-id>.png`, e.g. `DS-07.png`. |
| **Turn diagnostics** (Q13) | Privacy › Diagnostics › **Export** (`privacy.diagnostics.export`). Holds pill placement, orderFront/Out reasons, every dwell pause/resume with its reason + pointer + frame, every landing verdict + settle ms, every utterance decision (O3). Leave "include transcripts/audio" **off** unless the case says otherwise. Name the file `<case-id>-diag.json`. |
| **Unified log** | Terminal: `log stream --predicate 'subsystem == "in.adityakatare.voiceplus"' --level debug > <case-id>.log` while running the case; ⌃C after. |
| **"Why did it write that?"** (I3) | Menu-bar glyph › the status menu row "Why did it write that?" — screenshot the sheet. Holds the last 20 turns' stage trace (memory only). |
| **Lab result** | Model/data gates (§GT) write `Lab/results/…` — attach the file path. |
| **Screen recording** | ⌘⇧5 › Record selected portion — for motion cases (tape flight, Reduce Motion). |

### 0.4 Recording results
Each case row has **P/F** (Pass / Fail / Blocked / Not run), **Notes** and **Evidence** columns —
fill them in place in a copy of this file (`VoicePlus_HumanTest_<date>.md`). A case passes only if
every clause of **Desired outcome** holds. When a case fails, write what you saw in Notes (one line is
enough) and attach evidence; the build agent reproduces from the diagnostics export.

### 0.5 Conventions
- **⟨key⟩** = the configured dictation key (default **fn**; Settings › Shortcuts). **⟨act⟩** = the
  Actions key (off by default; Settings › Shortcuts / Settings › Computer use).
- "Hold-dictate X" = hold ⟨key⟩, say X, release. "Latch" = double-tap ⟨key⟩ (hands-free), tap ⟨key⟩ to finish.
- Pill states use the IDs of `DESIGN.md` §8.6 (I0 idle … Q2 meeting processing).
- "Settle" = wait 2 s after release before judging the landed text.
- Reset permissions between permission cases: `Packaging/reset_tcc.sh` (or System Settings ›
  Privacy & Security › the pane › remove VoicePlus).
- Model downloads are large; run them on Wi-Fi with ≥ 10 GB free (`df -h ~`).

### 0.6 Case count
| Section | Prefix | Cases |
|---|---|---|
| Owner actions (prerequisites, not tests) | OA | 26 |
| Install & permissions | IN | 32 |
| Onboarding | OB | 24 |
| Inputs | IP | 34 |
| Destinations | DS | 30 |
| Conditions (incl. K16 AirPods) | CN | 26 |
| Hardware-unverified surfaces (K23) | HU | 12 |
| §O concurrency matrix | OC | 20 |
| Meetings | MT | 36 |
| Notes | NT | 14 |
| Computer use | CU | 30 |
| Settings | ST | 93 |
| Recovery catalogue | RC | 59 |
| Accessibility | AX | 14 |
| The 16 §Q fixes | QF | 16 |
| Model / data / hardware gates | GT | 30 |

Total: 470 test cases (plus 26 owner actions). §17 maps every V5 item marked *partial* or *needs hardware* to its cases.

---

## 1. Owner actions (prerequisites)

These are not tests; they unblock tests. Each lists what to do, why, and which cases/gates it
unblocks. Mark **Done** with the date in Notes. Never download anything while `df -h ~` shows < 8 GB
free afterwards; the datasets below are listed with their size so you can stage them.

| ID | Action | Why / item | How | Unblocks | Done |
|---|---|---|---|---|---|
| OA-01 | **Q16** — remove the stale LaunchServices record | A stale `/Volumes/VoicePlus 1.12.10/VoicePlus.app` registration can open the wrong copy and confuse TCC | `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "/Volumes/VoicePlus 1.12.10/VoicePlus.app"` then the same tool with `-gc`; reboot; `lsregister -dump \| grep -i voiceplus` lists only `/Applications/VoicePlus.app` | IN-*, QF-16 | |
| OA-02 | **J4** — Developer ID certificate + notarization | Gatekeeper/quarantine/App Translocation still need it (SIGNING.md §5) | Join the Apple Developer Program, create a "Developer ID Application" certificate in Keychain, store a `notarytool` keychain profile; `Packaging/release.sh` then signs with it and runs `notarytool submit --wait` + `stapler staple` | IN-03, IN-04, GT-30 | |
| OA-03 | **J2** — CI runner | GitHub Actions on this account is restricted; workflow is manual-only (`workflow_dispatch`) | Either lift the account restriction (GitHub › Settings › Billing & plans) or register a self-hosted macOS runner (`[self-hosted, macOS]`), then run the workflow once by hand; `Scripts/ci-test.sh` runs the same thing locally | GT-29 | |
| OA-04 | Qwen3-ASR refinement weights | V4 `qwenRefinement` not measured; K21 "Ready" row look | Settings › Voice › Second pass › download (≈ 1.3 GB) | GT-01, ST rows for refinement, QF-15 | |
| OA-05 | **MUSAN** noise corpus (≈ 11 GB) | V3 noise mixing, B1/B5/C1/C1b gates, LR6 fused-in-noise | FluidInference mirror on Hugging Face; put under `~/Library/Application Support/VoicePlus/Eval/musan` (needs disk — consider an external drive and a symlink) | GT-02…GT-06, GT-22 | |
| OA-06 | **VOiCES** far-field set (subset ≈ 2–5 GB) | C1 VP-IO / C1b LocalVQE gate | voices18.github.io (CC-BY-4.0) → `Eval/voices` | GT-04, GT-05 | |
| OA-07 | **Earnings-22** (≈ 4 GB) | B1 entity-boosting gate | Hugging Face `revdotcom/earnings22` (CC-BY-SA-4.0) → `Eval/earnings22` | GT-02 | |
| OA-08 | **Svarah** (gated, Indian-accented English) | V1 en-IN baseline, B5 | Accept the gate on Hugging Face (AI4Bharat) with your account; download → `Eval/svarah` | GT-03, GT-07 | |
| OA-09 | **LibriSpeech test-other + FLEURS en-IN** | B5 Ultra/Redux ranking | `Eval/librispeech-test-other`, `Eval/fleurs-en_in` | GT-03 | |
| OA-10 | **LibriSpeech-PC** | D1 ITN numeric check, K8 prosody punctuation gate | Hugging Face `openslr/librispeech_pc` → `Eval/librispeech-pc` | GT-08, GT-09 | |
| OA-11 | **AMI + NOTSOFAR-1** (≈ 100 GB together; take the AMI headset-mix subset first) | L6 / O4 "ignore people talking to people" ≥ 95 %; M9 DER | AMI corpus site; NOTSOFAR on Hugging Face → `Eval/ami`, `Eval/notsofar1` | GT-10, GT-11, GT-12 | |
| OA-12 | **VoxConverse** | M9 WeSpeaker vs CAM++ DER | GitHub `joonson/voxconverse` → `Eval/voxconverse` | GT-12 | |
| OA-13 | **MUCS-2021 + HiACC** | G1 Srota vs base Qwen3-ASR | OpenSLR-104 + HiACC → `Eval/mucs2021`, `Eval/hiacc` | GT-13 | |
| OA-14 | **LRS3** (research licence) | LR6 lips eval | Accept the LRS3 licence; build the JSONL manifest described in `tools/avsr/README.md`; export `VOICEPLUS_LRS3_MANIFEST` | GT-14 | |
| OA-15 | **Smart Turn v3 → CoreML** (C4) | Upstream ships ONNX only | Convert `pipecat-ai/smart-turn-v3` (BSD-2) to `smart-turn-v3.mlmodelc` (input `input_features` [1, 80, 800] Float32, one scalar output); install under `~/Library/Application Support/VoicePlus/Models/smart-turn-v3/`; add BSD-2 attribution to `Packaging/model-notices` | CN-20, GT-15 | |
| OA-16 | **G1 Srota** Hinglish ASR conversion | `shipped = .srota` is a placeholder until converted | `tools/qwen3-asr-hinglish/convert.sh` on a machine with ~6 GB free; installs `Models/qwen3-asr-0.6b-hinglish/` | IP-31, GT-13 | |
| OA-17 | **LR2 Auto-AVSR** conversion | Fused AVSR / lips-only real use | `tools/avsr/README.md` steps 1–4 (non-commercial weights, LR4 accepted); output `Models/auto-avsr/` | IP-33, IP-34, GT-14 | |
| OA-18 | **CAM++ licence** (M9) | FunASR licence on the CAM++ weights unverified | Read the FunASR / 3D-Speaker model licence for `campplus` and record the verdict in `DECISIONS.md`; if not redistributable, keep WeSpeaker default | GT-12 | |
| OA-19 | **FluidUse pin bump for CUA-S1 4B** (CU2) | Pinned FluidUse `c9e967f` lacks `CuaS1FourBManager` → `UnavailableCuaS1Backend` | When FluidInference publishes a FluidUse release with `CuaS1FourBManager`, ask an agent to bump the pin in `Package.swift`; then download CUA-S1 4B (~4.0 GB) from Settings › Computer use | CU-24, GT-16 | |
| OA-20 | **IndicXlit** conversion (P6 / LANG2) | P6 is rule-based until the model is converted | Convert AI4Bharat IndicXlit (MIT) to CoreML; ask an agent to wire the catalog entry | IP-30, GT-17 | |
| OA-21 | **GLiNER2** weights + full **CMUdict** (P7 / P4 / M11) | Entity typing and phoneme path run on fallbacks | Settings › Dictionary & Apps › public lists (`dictionary.publicLists.download.*`) or ask an agent to fetch; GLiNER2 CoreML loads via ModelResidency | DS-29, MT-24, GT-18 | |
| OA-22 | On-demand models used by tests | Real-model cases | Settings › Models: Silero (bundled), LocalVQE (~50 MB), parakeet-ctc-110m (~103 MB), EOU 320, Parakeet Ultra (632 MB) / Redux (220 MB), Sortformer (255 MB), cleanup GGUF (~500 MB), Qwen3.5-2B (1.3 GB) or 4B (2.7 GB), Nemotron multilingual (664 MB) | many | |
| OA-23 | Kev / Intern / Laya decision models (O4) | Arbiter accuracy ≥ 90 % (Kev) | Download from Settings when Listen & act is first chosen, or ask an agent | OC-*, IP-25…27, GT-10 | |
| OA-24 | A Zoom/Meet/Teams account + one partner for 30 min | Meetings | Schedule a test call with a calendar invite listing the partner | MT-* | |
| OA-25 | A clean macOS user account (R3) | Fresh install / onboarding | System Settings › Users & Groups | IN-01, OB-*, HU-05 | |
| OA-26 | Sync partner Mac (F4) | Sync pairing / personas sync | Any second Mac with the same build | ST rows for Sync, RC-X05/X06 | |

---

## 2. Install & permissions (IN)

| ID | Area | Preconditions | Steps | Desired outcome | P/F | Notes | Evidence |
|---|---|---|---|---|---|---|---|
| IN-01 | Install · fresh | R3 clean account; no VoicePlus anywhere | Open the DMG, drag VoicePlus to `/Applications`, eject, launch from `/Applications` | App launches; onboarding window opens at Welcome with the "Setup · N of M" counter; menu-bar glyph present; no crash | | | |
| IN-02 | Install · not in /Applications | Fresh account | Launch VoicePlus straight from the mounted DMG | App asks to be moved to /Applications or explains why permissions will not stick; it never silently runs from the volume | | | |
| IN-03 | Install · Gatekeeper | Downloaded DMG (quarantined) | Open the app the first time | macOS shows the "unidentified developer" path (ad-hoc build) or, after OA-02, opens cleanly with no warning | | | |
| IN-04 | Install · App Translocation | Quarantined copy | Launch without moving it | No permissions granted to a translocated path; app tells you to move it | | | |
| IN-05 | Upgrade · in place | Previous release (1.12.12) installed with permissions granted and history | Install the V5 DMG over it, launch | All prior grants still work (Microphone, Accessibility) with no re-prompt; history, dictionary, personas, settings intact; onboarding does not restart | | | |
| IN-06 | Upgrade · data migration | 1.12.x with Ambient transcripts saved | Upgrade, open Notes | Legacy ambient transcripts appear in Notes (N4 fold); nothing duplicated or lost | | | |
| IN-07 | Upgrade · J5 updater | An older V5 build installed; a newer build on the appcast | Settings › Updates › **Check now** | Newer build offered on the chosen channel; install replaces the app only after download verified; drafts kept; relaunch works | | | |
| IN-08 | Upgrade · update interrupted | As IN-07 | Disconnect Wi-Fi mid-download | "The update didn't finish" (X07); installed version keeps working; retry resumes | | | |
| IN-09 | Mic · grant | Fresh TCC | Onboarding › Microphone › Allow → macOS prompt → Allow | Level meter moves when you speak; step completes | | | |
| IN-10 | Mic · deny | Fresh TCC | Allow microphone → Don't Allow | Copy switches to "Open System Settings"; never re-prompts in a loop; dead-end rule: system path + button + continue anyway + honest sentence | | | |
| IN-11 | Mic · "Later" (Q10) | Fresh TCC | Onboarding › Microphone › **Set up later**; finish onboarding; later press ⟨key⟩ | Pill shows E1 "Microphone access is off" with **Review permissions**; granting in System Settings is picked up live (no relaunch) — next ⟨key⟩ press records | | | |
| IN-12 | Mic · revoke mid-session | Mic granted, app idle | System Settings › Privacy › Microphone › turn VoicePlus off; press ⟨key⟩ | Live status re-read (Q10): E1 blocked, no recording claim, no crash | | | |
| IN-13 | Mic · revoke during capture | Hold-dictating | Revoke Microphone while holding ⟨key⟩ | Capture stops; words captured so far kept for review; P01 copy | | | |
| IN-14 | Accessibility · grant | Fresh TCC | Onboarding › Typing access › Allow → System Settings toggle | Grant detected live; Try dictation inserts into the test field | | | |
| IN-15 | Accessibility · deny | Fresh TCC | Skip Typing access | "Text will be held for you to paste until this is on"; dictations end in held text with Copy; Ready labelled copy-only | | | |
| IN-16 | Accessibility · Later then grant | IN-15 state | Grant Accessibility in System Settings | Next dictation inserts; if a relaunch is needed, P04 "Reopen VoicePlus to finish setup" with a working relaunch button | | | |
| IN-17 | Accessibility · revoke mid-session | Granted | Revoke, dictate into TextEdit | P02 "Allow VoicePlus to type"; text kept in recovery; no partial typing | | | |
| IN-18 | Screen Recording · opt-in (Q14) | Off | Settings › General › Insertion › "Confirm in apps that hide their text" → on | macOS Screen Recording prompt appears only now; with it denied the row explains and stays off | | | |
| IN-19 | Screen Recording · never asked by default | Fresh account, finish onboarding without Q14 | Use the app for 10 dictations | No Screen Recording prompt ever appears | | | |
| IN-20 | Camera · grant (LR1/LR5) | Off | Settings › Voice › camera row (lips) → on | Camera prompt; green camera indicator only while the mode is on; no frames saved (check `~/Library/Application Support/VoicePlus` has no new image/video files) | | | |
| IN-21 | Camera · deny | — | Deny the prompt | Mode stays off with an honest line; voice dictation unaffected | | | |
| IN-22 | Calendar · grant | Meetings detection | Settings › Meetings › calendars → grant Full Access | Upcoming meeting listed; detection signal active | | | |
| IN-23 | Calendar · deny | — | Deny | X01 "Meeting setup needs attention"; mic-only recording still works | | | |
| IN-24 | Contacts · grant | Dictionary › Import names from Contacts | Allow | Names imported; preview before commit | | | |
| IN-25 | Contacts · deny | — | Deny | X04 "Couldn't import these words"; existing dictionary unchanged | | | |
| IN-26 | Notifications · grant/deny | Meetings detection on | Trigger a detected meeting with notifications allowed, then denied | Allowed: one notification; denied: no crash, panel still shows the detected meeting | | | |
| IN-27 | Input Monitoring · default backend | Default bare-modifier monitor | Inspect System Settings › Input Monitoring | VoicePlus is **not** listed (1.6.8) and never prompts for it | | | |
| IN-28 | Input Monitoring · legacy tap (Q11) | Settings › Shortcuts › "Legacy event-tap listener" on | Enable it; grant Input Monitoring when prompted | Tap re-created on fresh grant without relaunch; pill shows "Listening again"; ⟨key⟩ works | | | |
| IN-29 | Input Monitoring · revoke with legacy tap | IN-28 | Revoke Input Monitoring | P03 "The shortcut needs permission"; no wedged state | | | |
| IN-30 | System audio · meetings | Meeting video-call mode | Start a meeting recording first time | System audio capture permission handled; missing system leg labelled (X01) | | | |
| IN-31 | Permissions pane | All granted | Open the permissions summary (Today readiness / Privacy) | Each permission shows its true live state; revoking one updates within a few seconds | | | |
| IN-32 | Uninstall/reinstall | Granted | Quit, drag to Trash, reinstall same DMG | TCC grants survive (build-independent designated requirement); no duplicate login item | | | |

---

## 3. Onboarding (OB)

Steps (`OnboardingStateMachine.Step`): **welcome → microphone → accessibility → model → firstDictation →
languages → voice → done**.

| ID | Area | Preconditions | Steps | Desired outcome | P/F | Notes | Evidence |
|---|---|---|---|---|---|---|---|
| OB-01 | Welcome | R3 fresh | Read the Welcome step | Heading "Your voice, a little closer."; still Spool cameo; Back hidden; **Begin setup** and Set up later visible; window is closable and not full-screen | | | |
| OB-02 | Progress | — | Move through steps | "Setup · N of M" text + bar update every step | | | |
| OB-03 | Microphone | — | Allow microphone | Real macOS prompt; real level meter; verdicts (waiting / no audio / too quiet / good / clipping) match what you do | | | |
| OB-04 | Microphone · no audio | Mute the input (hardware mute or a dead USB mic selected) | Speak | "no audio" verdict, never "good"; Choose microphone offered | | | |
| OB-05 | Typing access | — | Allow typing access | Explanation shown before the System Settings jump; returns and marks done live | | | |
| OB-06 | Model · download | No model installed | Install model | Progress bar; "verifying" then "loading" then ready with the model name; Continue only after ready | | | |
| OB-07 | Model · download interrupted | — | Turn Wi-Fi off mid-download | M04 "Model download paused"; retry resumes; no half-model marked installed (1.7.11) | | | |
| OB-08 | Model · disk full | Fill disk to < model size | Install model | M05 "Not enough space to finish setup"; nothing corrupt left behind | | | |
| OB-09 | Try dictation | Model ready | Hold ⟨key⟩, say "Hello world, this is my first sentence", release | Counterclockwise reels while speaking, words above the tape, review, clockwise feed into the safe test field; one uncertain word and its correction demonstrated | | | |
| OB-10 | Try dictation · fn conflict | ⟨key⟩ = fn; macOS "Press 🌐 to" = Show Emoji | Reach the key test | fn system-action prompt ("Open Keyboard settings") appears **before** the key test; button opens the right pane | | | |
| OB-11 | Try dictation · fn fallback | fn produces no event | Press fn three times | Offers Right ⌥ as the fallback key; choosing it works immediately | | | |
| OB-12 | Languages (LANG1) | — | Open the Languages step | Prefilled from macOS preferred languages + enabled keyboard sources; one script per language (Roman default) | | | |
| OB-13 | Languages · add Hindi | — | Add Hindi, script Roman; Continue | Route plan shows the needed speech models (Parakeet v3 / Hinglish / Nemotron) and their sizes; nothing downloads without asking | | | |
| OB-14 | Languages · English only | — | Keep English only | No extra model offered; English cleanup specialist kept | | | |
| OB-15 | Voice · enroll | — | Set up my voice; read four lines (~30 s) | Enrollment completes; "Voice learned"; filtering available in Voice | | | |
| OB-16 | Voice · skip | — | Skip | Hold dictation fully works; copy "Enrollment is optional. Hold-to-talk works without it." | | | |
| OB-17 | Voice · too short | — | Stop enrollment after 5 s | X03 "Couldn't finish voice setup"; hold-to-talk still works | | | |
| OB-18 | Ready · What to expect (I1) | All steps done | Read Ready | "You're ready." + What-to-expect card; small green dot explained; **Open VoicePlus** opens Today | | | |
| OB-19 | Ready · copy-only | Accessibility skipped | Reach Ready | Labelled copy-only (not "ready") | | | |
| OB-20 | Resume | Quit during Model step | Relaunch | Onboarding resumes at Model with earlier steps preserved | | | |
| OB-21 | Recovery · failed step | Force a model load failure (delete the model folder after download, before load) | Continue | Stays on the step with M07/M02 copy and a retry; earlier steps kept | | | |
| OB-22 | Back / Set up later | Mid-onboarding | Press Back on each step; then Set up later | Back returns without losing answers; Set up later closes; app usable within what is granted; Today shows what is unfinished | | | |
| OB-23 | Contacts import | Optional later step / Dictionary | Import names from Contacts | Preview → commit; rejected rows listed | | | |
| OB-24 | Run onboarding again | Completed | Settings › General › Run onboarding again | Starts at Welcome; existing grants detected as done; nothing reset | | | |

---

## 4. Inputs (IP)

| ID | Area | Preconditions | Steps | Desired outcome | P/F | Notes | Evidence |
|---|---|---|---|---|---|---|---|
| IP-01 | Hold | TextEdit focused | Hold-dictate "The quick brown fox jumps over the lazy dog." | C0 → C1 while held; F0 on release; D0 → D1 "✓ Inserted in TextEdit"; text exact | | | |
| IP-02 | Hold · too short | — | Tap ⟨key⟩ < 250 ms | K03 "Hold fn a little longer" (configured key name); nothing typed | | | |
| IP-03 | Hold · Esc cancel | — | Hold, speak, press Esc before release | C4 Cancelled "Nothing inserted"; nothing typed | | | |
| IP-04 | Latch | TextEdit | Double-tap ⟨key⟩, speak two sentences with a 3 s pause, tap ⟨key⟩ | C3 with timer; both sentences land; latch label persistent | | | |
| IP-05 | Latch · Esc | Latched | Esc | Cancel; nothing typed | | | |
| IP-06 | Latch · lock screen | Latched | ⌃⌘Q | Capture stops (K02); completed segments kept | | | |
| IP-07 | Menu start | — | Menu-bar glyph › Start dictation; speak; Stop | Explicit Stop control; text lands; menu never stole focus | | | |
| IP-08 | Wake verb `type` | Latched in TextEdit | Say "type hello there" | "hello there" typed (verb stripped) | | | |
| IP-09 | Wake verb `send` | Latched in Slack message box with text typed | Say "send it" | Message sent only by explicit verb; a dictated newline never sends (Q1) | | | |
| IP-10 | Wake verb `note` | Latched | Say "note buy milk tomorrow" | Goes to Notes, not the field; pill "📝 notes · 1" | | | |
| IP-11 | Wake verb `<app>` | Latched; Slack running | Say "in slack I'll be ten minutes late" | Slack focused and text placed in its message field | | | |
| IP-12 | Voice repair | Hold-dictate | Say "Meet at 5 pm, no, 6 pm" | Repair applied: "Meet at 6 pm" (or the configured repair behaviour), never both | | | |
| IP-13 | Edit selection | Select a sentence in TextEdit | Hold ⟨key⟩, say "make this more formal" | R1 Editing; edited preview before replacement; R2 Undo available 5 s and undo works | | | |
| IP-14 | Edit · stale range | IP-13 preview open | Change the selection before accepting | D10 "The text has changed"; nothing replaced | | | |
| IP-15 | Deixis box (H4) | A window with a button | Hold ⟨act⟩, say "click this" while pointing the mouse at the button | Time-aligned region (± 300 ms) resolves the element under the pointer at the word "this" | | | |
| IP-16 | Act key · off by default | Fresh settings | Press the configured act key | Nothing happens (off); Settings › Shortcuts explains | | | |
| IP-17 | Act key · on | Enable act key | Hold ⟨act⟩, say "open safari" | Safari opens; catalogue action; dictation key never triggers act (1.7.10) | | | |
| IP-18 | Ambient · Off | Ambient Off | Talk near the Mac for 1 min | Nothing captured or inferred; mic indicator off | | | |
| IP-19 | Ambient · Listen & note | Mode Listen & note | Say "remind me to call the dentist" with no key | A note is created; nothing typed or acted | | | |
| IP-20 | Ambient · Listen & act | Mode Listen & act; Kev model ready (OA-23) | Say "open the downloads folder" without a key | Acted only from your voice above the band; upper-middle band shows "Did you mean …?" confirm | | | |
| IP-21 | Ambient · irreversible self-confirm | Listen & act | Say "click delete" then "confirm" ambiently | An ambient utterance never confirms an irreversible step by itself — needs click or explicit confirm | | | |
| IP-22 | Ambient · switch by voice | Listen & act | Say "just take notes", then "stop listening" | Mode → Listen & note, then Off; menu/notch/Settings reflect it | | | |
| IP-23 | Ambient · menu/notch switch | — | Change ambient mode from the menu bar and from the pill/notch | Same three choices; state consistent everywhere | | | |
| IP-24 | Ambient · other voice | Listen & act; a second person speaks a command | Person 2 says "open safari" | Ignored (only the user's voice may start a capability); may be recorded only | | | |
| IP-25 | Ambient · TV | Listen & act; TV playing speech | 5 min | No action, no note from TV speech | | | |
| IP-26 | Ambient · arbiter decision log | Any ambient utterance | Export diagnostics | O3 decision row with owner, confidence, reason and question probabilities | | | |
| IP-27 | Ambient · "Not for you" | An ambient misfire | Use the correction ("Not for you") | Recorded; band nudge; next similar utterance less likely to fire | | | |
| IP-28 | Hard mute | — | Menu › Mute microphone; press ⟨key⟩ | I2 muted; K05 "VoicePlus is muted"; every capture closed; only explicit Unmute clears it | | | |
| IP-29 | Script menu (LANG2) | Hindi enabled | Pill script dropdown: Devanagari; dictate Hinglish in WhatsApp | Output in Devanagari; remembered for WhatsApp; danda only in Devanagari | | | |
| IP-30 | Script · transliteration quality | OA-20 done | Dictate 10 Hinglish sentences in Roman and Devanagari | Transliteration readable; names preserved | | | |
| IP-31 | Hinglish model | OA-16 done; Hindi + English chosen | Dictate "kal meeting 5 baje hai, please confirm" | Srota route used; English words Latin; no wrong-language guess | | | |
| IP-32 | Multilingual (Nemotron) | Nemotron downloaded; French enabled | Dictate a French sentence | Nemotron route; correct language; ITN locale per language | | | |
| IP-33 | Lips-only (LR3) | OA-17 done; camera on; Lips-only mode | Mouth a sentence silently | Mic muted; text appears from lips; reverts to voice when the model is missing | | | |
| IP-34 | Fused AV (LR2) | OA-17 done; camera on | Whisper a sentence | Fused result better than voice-only on the same whisper (compare with camera off) | | | |

---

## 5. Destinations (DS)

For each: hold-dictate **"First line. New paragraph. Second line with the number 1,250 and an email
test at example dot com."** unless the case says otherwise. Settle 2 s.

| ID | Area | Preconditions | Steps | Desired outcome | P/F | Notes | Evidence |
|---|---|---|---|---|---|---|---|
| DS-01 | TextEdit | New rich-text doc | Dictate | Exact text, paragraph break, "1,250", "test@example.com"; D1 verified | | | |
| DS-02 | Notes.app | New note | Dictate | Lands; verified or neutral "Inserted in Notes" | | | |
| DS-03 | Mail · body | New message, cursor in body | Dictate | Lands in body; thread participants (E6) used for name spelling (check I3 sheet) | | | |
| DS-04 | Mail · To field | Cursor in To | Dictate "priya at example dot com" | Compacted to an address; no sentence punctuation | | | |
| DS-05 | Slack · message | Channel message box | Dictate the two-paragraph text | **Never sends**: newline typed as ⇧↩ (Q1); both paragraphs in one unsent message | | | |
| DS-06 | Slack · thread | Thread reply box | Dictate | Lands in thread box; channel name/participants as context | | | |
| DS-07 | WhatsApp | Chat box | Dictate two paragraphs | Never sends; Hinglish per-app language memory if set | | | |
| DS-08 | Claude desktop · two paragraphs (Q1) | Claude prompt box | Dictate two paragraphs | Both paragraphs in the box, nothing submitted | | | |
| DS-09 | Claude · caret readable (Q2) | Claude prompt box | Dictate | Tape flies to the real caret (not window centre); E1 context from the conversation in I3 sheet | | | |
| DS-10 | Claude · neutral landing (Q4) | Claude | Dictate | If unreadable: plain "Inserted in Claude" (no ✓) auto-clears; never sticky "Couldn't confirm" unless a settled readback showed the text absent | | | |
| DS-11 | VS Code · editor | A .md file | Dictate | Lands at caret; newline is a newline (editor), not a run | | | |
| DS-12 | VS Code · integrated terminal | Terminal panel | Dictate "list files" (no newline) then two lines | Text typed, **never executed**: no Return sent | | | |
| DS-13 | Terminal.app | Prompt | Dictate "git status" + "new line" | Typed but not executed | | | |
| DS-14 | Cursor (Electron) | Chat box | Two paragraphs | ⇧↩ newline; nothing sent | | | |
| DS-15 | Google Docs (Chrome) | Doc body | Dictate | Lands; Q14 off → neutral landing; Q14 on → OCR caret band confirms | | | |
| DS-16 | Google Sheets · cell newline | A cell in edit mode | Dictate two lines | ⌥↩ inside the cell; never moves to the next cell or commits (Q1, E2) | | | |
| DS-17 | Google Sheets · column header | Column A header "Amount" | Dictate "twelve fifty" into A2 | Numeric formatting from the header (E2) | | | |
| DS-18 | Excel | Cell in edit mode | Dictate two lines | Same as DS-16 for Excel | | | |
| DS-19 | Numbers | Cell | Dictate | Lands in the cell; header used | | | |
| DS-20 | Figma | Text layer in edit mode | Dictate | Lands; canvas editor: Q14 band confirms when on, neutral otherwise | | | |
| DS-21 | Web form · Chrome | A sign-up form with labelled Name/Email/Phone | Dictate into each | Label/placeholder hints used (E3): email compacted, phone digits | | | |
| DS-22 | Web form · Safari | Same form | Dictate into each | As DS-21 in Safari | | | |
| DS-23 | Password field | Any login form, focus password | Hold ⟨key⟩ and speak | D03 "VoicePlus is paused in this field"; **nothing captured or inserted**; F3 turn discarded | | | |
| DS-24 | Browser sub-app (E5) | Chrome tabs: Gmail, GitHub, Docs | Dictate in each | Per-host persona/style applied (check I3 sheet) | | | |
| DS-25 | Read-only target | Click into a read-only web text | Dictate | D02 "Choose a text field"; text kept with Copy | | | |
| DS-26 | Never-inject app | Dictionary & Apps › app rule Never inject for TextEdit | Dictate in TextEdit | D04 "Dictation is off in this app" | | | |
| DS-27 | Destination changed | Hold-dictate, then ⌘Tab to another app before release | Release | H0 held: "Destination changed · text held" · Insert here / Copy / Discard; nothing typed into the new app | | | |
| DS-28 | Partial write | Hard to reproduce: dictate into a field that truncates (e.g. maxlength 10 web input) | Dictate 20 chars | D3/D07 "Only part may have been inserted"; Review shows both | | | |
| DS-29 | Entities | Dictionary has "Priya Raghunathan", "Postgres", "Kubernetes" | Dictate a sentence with all three | Correct spellings (B1 boosting); "stores" not turned into "Postgres" | | | |
| DS-30 | Cleanup model (D2) | AI cleanup on; GGUF downloaded | Dictate "um so basically I I think we should uh ship it friday" | Fillers removed, meaning intact; guard (D3) never adds facts; I3 sheet shows cleanup stage | | | |

---

## 6. Conditions (CN)

Use TextEdit and the reference sentence **"Please schedule the quarterly review with Priya for
Thursday at 3:30 pm."** unless stated. Record WER-ish judgement in Notes (words wrong / total).

| ID | Area | Preconditions | Steps | Desired outcome | P/F | Notes | Evidence |
|---|---|---|---|---|---|---|---|
| CN-01 | Quiet room | Built-in mic | 10 dictations | ≥ 9/10 exact | | | |
| CN-02 | TV on | TV speech at normal volume 3 m away | 10 dictations | Your words only; no TV words inserted; C5 warning only if real | | | |
| CN-03 | Person 2–3 ft away (K2/K4) | Person 2 talks continuously | 10 dictations | Near-field gate + turn-anchored voice: their words not inserted | | | |
| CN-04 | Whisper | — | 10 whispered dictations | Usable text; no invented words (1.6.9) | | | |
| CN-05 | Loud room | Music/babble ~70 dB | 10 dictations | Warning C5 if unclear; words kept | | | |
| CN-06 | Noise reduction Apple (C1) | Settings › Voice › Noise and echo reduction = Apple | Repeat CN-02/CN-05 | Compare to Off; note AGC log line; 300 ms warm-up not clipping first word | | | |
| CN-07 | Noise reduction LocalVQE (C1b) | LocalVQE downloaded; set LocalVQE | Repeat CN-02/CN-05 | Compare; no artefacts; loads via residency | | | |
| CN-08 | K16 · 10 built-in dictations | Built-in mic | 10 dictations; note first-word latency | All land; first word not clipped | | | |
| CN-09 | K16 · 10 AirPods dictations | AirPods connected, selected | 10 dictations | All land; narrowband chip (C3) if HFP; quality acceptable | | | |
| CN-10 | K16 · switch mid-utterance | AirPods | Start dictating, take AirPods out mid-sentence | Device change handled: A02 "Microphone disconnected" with partial text kept, or seamless fallback; never a wedge | | | |
| CN-11 | K16 · HFP narrowband | AirPods in a call (HFP) | Dictate | Narrowband chip + Settings link (C3); text still lands | | | |
| CN-12 | K16 · 10-min idle cold graph | AirPods; idle 10 min | Dictate | First dictation after idle works; first word not lost; latency recorded | | | |
| CN-13 | AirPods mic modes (K5) | AirPods | Voice › Mic Modes… → Voice Isolation / Wide Spectrum | Row opens the system mic-mode UI; wideband re-measure noted | | | |
| CN-14 | Device change between turns | USB mic + built-in | Dictate, switch input in Voice picker, dictate | Second turn uses the new device; no stale graph | | | |
| CN-15 | Device unplugged idle | USB mic selected | Unplug, dictate | A01/A03 copy; Choose microphone | | | |
| CN-16 | External display | R2 | Dictate into apps on the external display | Pill on the display with the caret (Q6) | | | |
| CN-17 | AirPlay display | AirPlay mirror/extend to a TV | Dictate | Pill on the right screen; no lost pill | | | |
| CN-18 | Only react to my voice (K3) | Enrolled; toggle on | Person 2 hold-dictates on your Mac | Their speech filtered; yours passes | | | |
| CN-19 | Two-speaker room (K4) | Person 2 interjects mid-sentence | Dictate | Only your turn-anchored voice lands | | | |
| CN-20 | Smart Turn endpointing (C4) | OA-15 done; latched | Latch, speak a finished sentence, pause 0.5 s | Segment ends early on a finished sentence; unfinished sentence waits | | | |
| CN-21 | EOU 320 ms (C5) | EOU 320 downloaded | Compare live preview with 160 default | Note preview quality/latency | | | |
| CN-22 | Mic-quality floor (K6) | — | Start dictating immediately after key-down | No false "unclear" warning in the first 100 ms | | | |
| CN-23 | Memory pressure (HW3) | Open many heavy apps until memory pressure is critical | Dictate | Pill chip "Running lighter models — memory is low"; dictation continues on lighter model; chip clears when normal | | | |
| CN-24 | Long dictation | — | Latch 5 minutes of speech | All text lands; no truncation; F3 stores audio within cap | | | |
| CN-25 | Sleep/wake | Latched | Close lid, reopen | Capture stopped (K02); recovered text offered | | | |
| CN-26 | Accented / Indian English | — | 10 dictations with names and ₹ amounts ("two lakh rupees") | en-IN ITN: "₹2,00,000"; day-first dates if en-IN | | | |

---

## 7. Hardware-unverified surfaces carried from 1.11–1.12 (K23) (HU)

| ID | Area | Preconditions | Steps | Desired outcome | P/F | Notes | Evidence |
|---|---|---|---|---|---|---|---|
| HU-01 | Tape flight on real carets | TextEdit, Notes, Safari textarea, Slack | Dictate in each; screen-record | Tape flies from Spool's mouth to the real caret position in each app | | | |
| HU-02 | Confidence marks on real carets | Dictate a sentence with a rare word | Look at the landed text | Dotted marks align with the uncertain word's rectangle, or D09 "Word marks aren't available in this app" — never floating inaccurate marks | | | |
| HU-03 | Notch placement | Notched display | Idle, hover, dictate | 64 × 14 pt chin centred under the notch; pill grows from it without covering the menu bar items | | | |
| HU-04 | No-notch placement | R5 | Same | Chin/pill centred at the top of the active display | | | |
| HU-05 | Onboarding on a clean account | R3 | Full onboarding | No clipped buttons (1.7.5); all steps reachable | | | |
| HU-06 | Onboarding on an external monitor | R2, onboarding window dragged there | Full onboarding | Layout intact; prompts appear on the right display | | | |
| HU-07 | fn system-action prompt | OB-10 conditions | Follow the prompt | System Settings › Keyboard opens at the 🌐 setting; after changing it, fn dictates | | | |
| HU-08 | Physical global Escape | Dictating in another app | Press the physical Esc key | Cancels the turn globally; Esc is not delivered as a stray key to the app mid-turn | | | |
| HU-09 | Destination-change recovery | DS-27 | Use Insert here | Inserted once at the new caret; held cleared | | | |
| HU-10 | Partial-write recovery | DS-28 | Review inserted text → reconcile | No duplicate text after reconciliation | | | |
| HU-11 | VoiceOver cursor on the pill | VoiceOver on (⌘F5) | Dictate; VO-navigate to the pill | Pill readable; buttons (Insert now / Edit draft / Cancel) reachable and announced | | | |
| HU-12 | High contrast | Accessibility › Display › Increase Contrast | Walk all pill states | Text meets contrast; borders visible | | | |

---

## 8. §O concurrency matrix (OC)

Every cell of `VoicePlus_Improvements_V5.md` §O-c. Use the diagnostics export (O3 decision rows) as
evidence for each.

| ID | Area | Preconditions (already running) | Steps (new input) | Desired outcome | P/F | Notes | Evidence |
|---|---|---|---|---|---|---|---|
| OC-01 | Hold × Meeting | Meeting recording | Hold-dictate into TextEdit | Dictates into TextEdit; meeting transcript shows it tagged "dictated" | | | |
| OC-02 | Hold × Latch | Latch session open | Hold ⟨key⟩ and speak | Hold takes over that turn; latch resumes after | | | |
| OC-03 | Hold × Agent | Agent (CUA) running a multi-step goal | Hold-dictate a sentence | Goes to Notes (not into the agent's app) unless it is "stop" | | | |
| OC-04 | Hold × Ambient | Listen & act | Hold-dictate | Explicit wins: dictation lands; no ambient decision on it | | | |
| OC-05 | Latch × Meeting | Meeting recording | Double-tap latch, speak | Latch output → Notes; tagged in meeting | | | |
| OC-06 | Latch × Latch | Latch open | Double-tap again | No second latch (— in matrix): same session continues or stops cleanly | | | |
| OC-07 | Latch × Agent | Agent running | Double-tap, speak | Notes | | | |
| OC-08 | Latch × Ambient | Listen & act | Double-tap, speak | Explicit wins: latch owns it | | | |
| OC-09 | Act × Meeting | Meeting recording | Hold ⟨act⟩, "open safari" | Acts; tagged "command" in meeting | | | |
| OC-10 | Act × Latch | Latch open | Hold ⟨act⟩, "scroll down" | Latch paused for the turn; resumes after | | | |
| OC-11 | Act × Agent | Agent running | Hold ⟨act⟩, "stop" then (new run) "open notes" | "stop" stops the agent; non-stop/confirm act does not replace the running agent | | | |
| OC-12 | Act × Ambient | Listen & act | Hold ⟨act⟩ | Explicit wins | | | |
| OC-13 | Ambient utt × Meeting | Meeting + Listen & note | Say a note-like sentence | Recorded in meeting; may also note per mode | | | |
| OC-14 | Ambient utt × Latch | Latch open + Listen & act | Say "open safari" without the act key | Latch owns it (typed as text or wake-verb handled), not acted ambiently | | | |
| OC-15 | Ambient utt × Agent | Agent running + Listen & act | Speak a command | Notes | | | |
| OC-16 | Ambient utt × Ambient | Listen & act idle | Say commands at high / mid / low confidence ("open downloads", "maybe check mail later", chit-chat) | High → act; upper-middle → "Did you mean …?" ask; lower-middle → Note; low → ignore | | | |
| OC-17 | Remote voice × Meeting | Video call recording | Remote person says "open safari" | Recorded only | | | |
| OC-18 | Remote voice × Latch | Latch open during a call | Remote person speaks | Ignored (not typed) | | | |
| OC-19 | Remote voice × Agent | Agent running during a call | Remote person says "stop" | Ignored | | | |
| OC-20 | Remote voice × Ambient | Listen & act during a call | Remote person says a command | Ignored | | | |

---

## 9. Meetings (MT)

| ID | Area | Preconditions | Steps | Desired outcome | P/F | Notes | Evidence |
|---|---|---|---|---|---|---|---|
| MT-01 | Mode · video call (M1) | Zoom call with 1 partner | Start recording | Both legs captured and diarized; Q0 pill with timer and track status | | | |
| MT-02 | Mode · in-person (M2) | Two people in the room | Start recording, In-person | Mic diarized; two speakers | | | |
| MT-03 | Mode · hybrid (M3) | Call + one person in room | Hybrid | Both legs; cross-leg echo veto: remote speech heard through speakers not duplicated as a local speaker | | | |
| MT-04 | Mode · auto-pick (M4) | — | Start without choosing | Correct mode picked; override from the panel mode pill works | | | |
| MT-05 | Save recording · Always (M5) | Default | Record 2 min | Per-leg WAV saved; Privacy shows it | | | |
| MT-06 | Save recording · 7 days / Never | Change setting | Record | 7 days: swept after 7 days (check date math); Never: no audio file kept, live labels still shown | | | |
| MT-07 | Shared cap (F3) | Many recordings | Exceed the 2 GB cap | Oldest swept LRU; dictation + meeting share the cap | | | |
| MT-08 | Pause / resume / stop | Recording | Pause, Resume, Stop | Q1 paused (stationary reels); Stop → Q2 processing → notes | | | |
| MT-09 | Detection · calendar | Calendar event now with a video link | Wait | Detected-meeting notification/panel | | | |
| MT-10 | Detection · camera | Camera in use by Zoom | — | Detected | | | |
| MT-11 | Detection · mic used by another app | FaceTime call | — | Detected (mic-elsewhere) | | | |
| MT-12 | Detection · call app running | Teams launched, in a call | — | Detected | | | |
| MT-13 | Detection · browser tab | Google Meet in Chrome/Safari/Arc | — | Detected from tab URL/title; tab switch away clears it | | | |
| MT-14 | Detection · don't-notify list | Add Chrome to don't-notify | Meet in Chrome | No notification; every recognised browser offered in the list | | | |
| MT-15 | Detection · reminder at start | Reminder on | Event start | Reminder appears at start time | | | |
| MT-16 | Auto-record calendar meetings | Default off; turn on | Calendar meeting starts | Off: never records automatically; On: records | | | |
| MT-17 | Own capture not a signal | VoicePlus itself dictating | — | Its own mic use never triggers detection | | | |
| MT-18 | Lock/sleep stands meeting down (O1) | Recording | Lock screen | Meeting stops cleanly; recording saved | | | |
| MT-19 | Live transcript (M15) | Recording | Watch the panel | Live words with speaker labels | | | |
| MT-20 | Dictation during a meeting (M14) | Recording | Hold-dictate into Notes.app | Lands; tagged "dictated"; "Show my dictations" switch hides/shows them | | | |
| MT-21 | Live labels · Sortformer (M7) | Sortformer downloaded | 3-person call | ≤ 4 speakers per stream; stable labels | | | |
| MT-22 | Final re-diarization (M8) | After stop | Open meeting | Labels refined over saved WAV; Never-save keeps live labels | | | |
| MT-23 | Passive voiceprint (M6) | ≥ 5 dictation turns | Record a meeting | You are labelled "You" without enrollment; "Voice learned" shown once | | | |
| MT-24 | Name hints (M11) | Calendar invite lists partner; partner addressed by name | Record | "maybe <name>" suggestions from calendar / Zoom active speaker / "Thanks, Priya" | | | |
| MT-25 | Descriptive labels (M13) | 2 unknown speakers | Open meeting | Unique 2–3 attribute labels ("Deep voice · on the call (Zoom) …"); "probably" for perceived gender | | | |
| MT-26 | Perceived gender switch | Settings › Meetings perceived gender off | Re-open | Labels without gender | | | |
| MT-27 | Hover card + Map to… (M13/M10) | — | Hover a label; play snippet; Map to contact | Snippet plays; mapping saved; next meeting auto-matches (high applied, middle suggested) | | | |
| MT-28 | Notes · templates (M17) | Local model (Qwen3.5) ready | Generate notes with each of the 5 templates | Notes produced; extractive fallback if the model fails; retry works | | | |
| MT-29 | Ask · live (M16) | Recording | Ask "what did they say about the budget?" | Answer with citations to transcript windows | | | |
| MT-30 | Ask · after, local backend (M21) | Finished meeting | Ask | Answer + citations; seek to cited moment works | | | |
| MT-31 | Ask · each backend (M22/M24) | claude CLI / codex CLI / ChatGPT OAuth / BYO key / Ollama | Pick each in Meetings provider picker; ask | Each works or shows N01–N04 recovery honestly; no silent cloud fallback | | | |
| MT-32 | Ask across meetings (M19) | ≥ 3 meetings | Library header Ask | Cross-meeting answer cites each meeting | | | |
| MT-33 | Named transcript, search, seek (M18) | — | Search a word; click result | Seeks audio to it | | | |
| MT-34 | Export + auto-export (M20) | Auto-export folder set | Finish a meeting | Markdown file in the folder with the right names; manual export identical | | | |
| MT-35 | Post-meeting hook | Hook script set (e.g. `cat > /tmp/hook.json`) | Finish a meeting | JSON on stdin matches the export | | | |
| MT-36 | MCP server (M23) | Settings › Providers › MCP server on | Connect Claude Desktop to it; list meetings | Off by default; token in Keychain; 4 tools work; off again → refused | | | |

---

## 10. Notes (NT)

| ID | Area | Preconditions | Steps | Desired outcome | P/F | Notes | Evidence |
|---|---|---|---|---|---|---|---|
| NT-01 | Route · no focused field | Click the desktop (Finder, no text field) | Hold-dictate | Stored in Notes (no D02 hold); pill notes chip increments | | | |
| NT-02 | Route · app switch mid-segment | Latched | ⌘Tab to another app mid-sentence | Segment goes to Notes, not the new app | | | |
| NT-03 | Route · wake verb | Latched | "take a note call mum" | Note "call mum" | | | |
| NT-04 | Route · ambient lower-middle band | Listen & act | Say something half-directed ("I should probably check the invoices") | Note | | | |
| NT-05 | Route · declined ask | Listen & act, upper-middle | Decline "Did you mean …?" | Kept as a note | | | |
| NT-06 | Route · Listen & note | Listen & note | Speak | Notes only | | | |
| NT-07 | Route · latch during meeting | Meeting recording | Latch and speak | Notes | | | |
| NT-08 | Route · agent running | Agent running | Hold-dictate | Notes | | | |
| NT-09 | Route · another voice (K4) | Latch; person 2 speaks | — | Suppressed speech goes to Notes, not the field | | | |
| NT-10 | Notes section (N1) | Several notes | Open Notes (⌘3) | By day/session, source tag per row, search works, unread badge | | | |
| NT-11 | Insert here / Copy / Discard | A note; TextEdit focused | Use each action | Insert here lands at caret; Copy copies; Discard removes after confirm | | | |
| NT-12 | Insert all | 3 notes | Insert all into TextEdit | All three in order | | | |
| NT-13 | Export | — | Export | File with all notes | | | |
| NT-14 | Pill chip (N3) | Unread notes | Look at pill / menu | "📝 notes · N" chip and menu row open Notes | | | |

---

## 11. Computer use (CU)

Enable Settings › Computer use and the ⟨act⟩ key. Each catalogue case: hold ⟨act⟩, say the phrase.

| ID | Area | Preconditions | Steps | Desired outcome | P/F | Notes | Evidence |
|---|---|---|---|---|---|---|---|
| CU-01 | Catalogue · focusApp | — | "open safari" | Safari frontmost | | | |
| CU-02 | Catalogue · open {arg} | — | "open calculator" | Calculator opens | | | |
| CU-03 | Catalogue · focusWindow | Two Safari windows | "next window" | Next window focused | | | |
| CU-04 | Catalogue · windowOp | — | "minimize window" | Minimized (reversible) | | | |
| CU-05 | Catalogue · switchSpace | 2+ Spaces | "desktop right" | Next Space | | | |
| CU-06 | Catalogue · openURL | — | "open url example.com" | Opens in default browser | | | |
| CU-07 | Catalogue · openFile | — | "open downloads" | Finder at Downloads | | | |
| CU-08 | Catalogue · scroll | Long page | "scroll down" | Scrolls | | | |
| CU-09 | Catalogue · typeText | TextEdit | "type hello world" | Typed | | | |
| CU-10 | Catalogue · click {arg} | A dialog with OK | "click ok" | Semi: undo toast; clicked | | | |
| CU-11 | Catalogue · fillField | Search field on a page | "search for swift testing" | Field filled | | | |
| CU-12 | Catalogue · focusTab | Several tabs | "next tab" / "switch to tab GitHub" | Correct tab | | | |
| CU-13 | Catalogue · shortcut (browser) | Safari | "new tab" | New tab | | | |
| CU-14 | Catalogue · shortcut (semi) | Safari tab | "close tab" | Closed with undo toast | | | |
| CU-15 | Catalogue · editor | VS Code | "format document" | Formatted | | | |
| CU-16 | Catalogue · save | TextEdit edited | "save" | Saved (semi) | | | |
| CU-17 | Catalogue · chat | Slack message typed | "send" | Semi: sent only by this explicit act | | | |
| CU-18 | Catalogue · irreversible | Mail draft to yourself | "click send email" | Irreversible → spoken "confirm" or click required before sending | | | |
| CU-19 | Catalogue · irreversible (chat) | Slack message of yours | "delete message" | Consent required; cancel leaves it | | | |
| CU-20 | Catalogue · paraphrase | — | "bring up safari please" / "go one desktop to the right" | Retrieval (CU4) resolves paraphrases ≥ 0.8 directly; else CUA-S1/planner | | | |
| CU-21 | Planner · local Qwen3.5 (CU8) | 2B/4B downloaded (size by RAM) | "find the latest invoice email and forward it to me" | JSON StepPlan with step chips; steps execute; consent at semi/irreversible | | | |
| CU-22 | Planner · Ollama / LM Studio | Pinned local server | Same goal | Plans offline | | | |
| CU-23 | Planner · cloud/CLI | claude/codex CLI or key | Same goal | Works; egress shown in Privacy | | | |
| CU-24 | CUA-S1 4B (CU2) | OA-19 done | "click the blue Continue button" in a web app | Element chosen from the AX tree; never coexists with a 4B planner (CU9) | | | |
| CU-25 | Forms chooser | A web form | "fill name with Priya" | Right field filled (cua-s1-forms) | | | |
| CU-26 | Consent · reversible | — | Reversible action | Runs immediately | | | |
| CU-27 | Consent · semi | — | Semi action | Runs with undo toast; undo works | | | |
| CU-28 | Consent · irreversible default | Settings › Computer use › irreversible consent | Change default; run CU-18 | Setting respected; never self-confirmed by ambient speech | | | |
| CU-29 | Stop mid-flight | Multi-step goal running | Say "stop" (⟨act⟩) / press Esc / pill Stop | Stops before the next step; compensation where defined; nothing further executed | | | |
| CU-30 | Ambient act (CU7) | Listen & act | Say "scroll down" without the key | Acts via the act-key path above band; no ambient confirm of irreversible | | | |

---

## 12. Settings (ST)

Every row indexed by `MainWindowSection` / `SettingsReachability` must be reachable **and** have a
visible effect. Open the one window (menu › Open VoicePlus; ⌘1–⌘7 for sections; ⌘, for Settings).
For each row: find it at the given address, change it, and observe the stated effect; then restore it.

### 12.1 Indexed rows (`SettingsReachability.items` + `newlySurfaced`)
| ID | Area | Preconditions | Steps | Desired outcome | P/F | Notes | Evidence |
|---|---|---|---|---|---|---|---|
| ST-01 | Settings · Dictation key | Window open at **Settings (⌘7) › Shortcuts** (`settings.hotkey`) | Record a new key (e.g. Right ⌥); dictate with it | Row is present at that address. New key works at once; old key no longer starts dictation; conflict shows K01 and keeps the prior binding | | | |
| ST-02 | Settings · Dictation key permission note | Window open at **Settings (⌘7) › Shortcuts** (`settings.hotkeyPermissionNote`) | Choose a key that needs the legacy tap | Row is present at that address. Note explains Input Monitoring is needed only for that backend | | | |
| ST-03 | Settings · Actions key | Window open at **Settings (⌘7) › Shortcuts** (`settings.actKey`) | Turn the Actions key on, bind it, then off | Row is present at that address. On: ⟨act⟩ acts; off: nothing; never shares the dictation key (1.7.10/1.7.14) | | | |
| ST-04 | Settings · Actions key note | Window open at **Settings (⌘7) › Shortcuts** (`settings.actKeyNote`) | Read the note with the key off/on | Row is present at that address. Note matches the state | | | |
| ST-05 | Settings · Legacy event-tap listener | Window open at **Settings (⌘7) › Shortcuts** (`settings.forceEventTap`) | Toggle on/off | Row is present at that address. On: Input Monitoring requested, tap live (IN-28); off: bare-modifier monitor, VoicePlus leaves Input Monitoring | | | |
| ST-06 | Settings · Show indicator under the notch | Window open at **Settings (⌘7) › Appearance** (`settings.presenceIndicator`) | Toggle off/on | Row is present at that address. Off: idle chin hidden (dictation still works); on: chin back | | | |
| ST-07 | Settings · Hide it in full screen | Window open at **Settings (⌘7) › Appearance** (`settings.presenceHideInFullScreen`) | On; open a full-screen app | Row is present at that address. Chin hidden in full screen on that display only (Q7) | | | |
| ST-08 | Settings · Run onboarding again | Window open at **Settings (⌘7) › General** (`settings.runOnboardingAgain`) | Press it | Row is present at that address. Onboarding opens at Welcome; grants shown as done (OB-24) | | | |
| ST-09 | Settings · Silent corrections | Window open at **Settings (⌘7) › General** (`CorrectionSettingsSection(`) | Toggle; correct a word in a dictation | Row is present at that address. On: correction learned silently; off: nothing learned | | | |
| ST-10 | Settings · Launch at login | Window open at **Settings (⌘7) › General** (`settings.launchAtLogin`) | Toggle on; log out/in | Row is present at that address. Starts at login when on; not when off; failure shows the row error | | | |
| ST-11 | Settings · Microphone picker | Window open at **Voice (⌘5)** (`settings.microphone`) | Pick a different input; dictate | Row is present at that address. Next turn uses the picked device (CN-14) | | | |
| ST-12 | Settings · Microphone note | Window open at **Voice (⌘5)** (`settings.microphoneNote`) | Pick an AirPods/Bluetooth input | Row is present at that address. Note explains narrowband/latency | | | |
| ST-13 | Settings · Save recordings | Window open at **Privacy (⌘6)** (`settings.saveRecordings`) | Toggle off; dictate | Row is present at that address. Off: no dictation audio kept; on: audio + sidecar saved (F3) | | | |
| ST-14 | Settings · Save recordings note | Window open at **Privacy (⌘6)** (`settings.saveRecordingsNote`) | Read | Row is present at that address. Copy explains retention and never-synced | | | |
| ST-15 | Settings · Recordings on disk / reveal / delete | Window open at **Privacy (⌘6)** (`settings.recordings`) | Reveal; delete one; delete all | Row is present at that address. Finder opens the folder; deletions reflected; counts accurate (S04 on partial) | | | |
| ST-16 | Settings · Per-stage routing | Window open at **Settings (⌘7) › Models** (`settings.routing.`) | Pin a stage (e.g. cleanup) to a provider; dictate | Row is present at that address. Stage uses that provider (I3 sheet shows it); egress listed in Privacy if remote | | | |
| ST-17 | Settings · Reset all to Auto | Window open at **Settings (⌘7) › Models** (`settings.resetRoutingToAuto`) | Press it | Row is present at that address. All stage pins back to Auto | | | |
| ST-18 | Settings · Speech model summary | Window open at **Settings (⌘7) › Models** (`settings.speechModel`) | Read; switch model | Row is present at that address. Shows the active model + size; switch takes effect after verify/load | | | |
| ST-19 | Settings · Connected providers | Window open at **Settings (⌘7) › Providers** (`settings.connectedProviders`) | Connect / disconnect a provider | Row is present at that address. List updates; credentials in Keychain; N02 on bad key | | | |
| ST-20 | Settings · Connect what you pay for | Window open at **Settings (⌘7) › Providers** (`settings.connectProviders`) | Open it | Row is present at that address. Shows claude/codex CLI, ChatGPT OAuth, BYO key, Ollama/LM Studio options | | | |
| ST-21 | Settings · Refinement mode and its honest availability note | Window open at **Voice (⌘5)** (`VoiceSettingsTab(`) | Set refinement mode with and without weights (OA-04) | Row is present at that address. "Ready" only when weights are size-verified (K21); otherwise an honest note; refinement applied when ready | | | |
| ST-22 | Settings · Persona list | Window open at **Dictionary & Apps (⌘4)** (`apps.personas.list`) | Open | Row is present at that address. Personas listed per app | | | |
| ST-23 | Settings · Persona app bundle ID | Window open at **Dictionary & Apps (⌘4)** (`apps.personas.bundleID`) | Choose an app for a persona | Row is present at that address. Persona applies only in that app | | | |
| ST-24 | Settings · Persona instructions | Window open at **Dictionary & Apps (⌘4)** (`apps.personas.instructions`) | Edit instructions; dictate in that app | Row is present at that address. Style follows the instructions | | | |
| ST-25 | Settings · Auto-draft from my style | Window open at **Dictionary & Apps (⌘4)** (`apps.personas.autoDraft`) | Run it after ≥ 20 dictations in an app | Row is present at that address. Draft persona from your edits (F1); your edits never overwritten | | | |
| ST-26 | Settings · Save persona | Window open at **Dictionary & Apps (⌘4)** (`apps.personas.save`) | Save; relaunch | Row is present at that address. Persists; S02 on failure keeps the value | | | |
| ST-27 | Settings · Filter | Window open at **Dictionary & Apps (⌘4)** (`dictionary.filter`) | Type in the filter / ⌘F | Row is present at that address. List narrows; clear restores | | | |
| ST-28 | Settings · Add term | Window open at **Dictionary & Apps (⌘4)** (`dictionary.add`) | Add "Raghunathan"; dictate it | Row is present at that address. Term spelled right next time | | | |
| ST-29 | Settings · Train by voice | Window open at **Dictionary & Apps (⌘4)** (`dictionary.trainByVoice`) | Train a term by voice | Row is present at that address. Spoken form recorded; recognised after | | | |
| ST-30 | Settings · Import names from Contacts | Window open at **Dictionary & Apps (⌘4)** (`dictionary.importContacts`) | Import | Row is present at that address. IN-24/IN-25 behaviour | | | |
| ST-31 | Settings · Learned automatically / Forget | Window open at **Dictionary & Apps (⌘4)** (`dictionary.learned`) | Forget a learned word | Row is present at that address. Gone from list and no longer biases | | | |
| ST-32 | Settings · Spoken snippets | Window open at **Dictionary & Apps (⌘4)** (`SnippetsSettingsTab(`) | Add trigger "my address" → body; dictate "my address" | Row is present at that address. Body inserted | | | |
| ST-33 | Settings · Flag toggles | Window open at **Privacy (⌘6)** (`privacy.diagnostics.flag.`) | Toggle a flag (e.g. previewBackend); dictate | Row is present at that address. Behaviour changes; flag verdict text matches A3 | | | |
| ST-34 | Settings · Reset to defaults | Window open at **Privacy (⌘6)** (`privacy.diagnostics.flagsReset`) | Press it | Row is present at that address. All flags default | | | |
| ST-35 | Settings · Connected services | Window open at **Settings (⌘7) › Providers** (`ConnectorsSettingsTab(`) | Connect GitHub with a token; disconnect | Row is present at that address. Token in Keychain; act connectors use it | | | |
| ST-36 | Settings · Pairing, folder transport, export/import | Window open at **Settings (⌘7) › Sync** (`SyncSettingsTab(`) | Pair with OA-26 Mac; sync now; export/import | Row is present at that address. Personas/dictionary sync; recordings never synced; X05/X06 on tamper/conflict | | | |
| ST-37 | Settings · Egress log | Window open at **Privacy (⌘6)** (`privacy.egressTable`) | Use a cloud provider once; refresh | Row is present at that address. Row with host, bytes, reason; only reviewed hosts (I4) | | | |
| ST-38 | Settings · Bytes out today | Window open at **Privacy (⌘6)** (`privacy.bytesOutToday`) | After egress | Row is present at that address. Counter increases | | | |
| ST-39 | Settings · Refresh | Window open at **Privacy (⌘6)** (`privacy.egressRefresh`) | Press | Row is present at that address. Table refreshes | | | |
| ST-40 | Settings · Block all network egress | Window open at **Privacy (⌘6)** (`privacy.killSwitch`) | Kill switch on; try model download / cloud Ask | Row is present at that address. Every network call refused with an honest message; local dictation works | | | |
| ST-41 | Settings · Ranked-context-list counters | Window open at **Voice (⌘5)** (`benchmark.row`) | After 20 dictations | Row is present at that address. Counters non-zero | | | |
| ST-42 | Settings · No measurements yet | Window open at **Voice (⌘5)** (`benchmark.empty`) | Fresh account | Row is present at that address. Empty-state copy | | | |
| ST-43 | Settings · Recall gain | Window open at **Voice (⌘5)** (`benchmark.recallGain`) | After benchmarks | Row is present at that address. Shows a value | | | |
| ST-44 | Settings · Within / over budget | Window open at **Voice (⌘5)** (`benchmark.passLabel`) | After benchmarks | Row is present at that address. Pass label correct | | | |
| ST-45 | Settings · Never inject into this app (R2.3) | Window open at **Dictionary & Apps (⌘4)** (`apps.neverInject`) | Set for TextEdit | Row is present at that address. DS-26 behaviour | | | |
| ST-46 | Settings · Ambient capture | Window open at **Privacy (⌘6)** (`privacy.ambientCapture`) | Change ambient mode here (Off / Listen & note / Listen & act) | Row is present at that address. Same state as menu/notch (IP-23); explainer shown | | | |
| ST-47 | Settings · Keep other voices too (R8.1) | Window open at **Privacy (⌘6)** (`privacy.ambientEverySpeaker`) | Toggle; let person 2 speak in Listen & note | Row is present at that address. Off: other voices not kept; on: recorded only, never acted | | | |
| ST-48 | Settings · Transcript retention | Window open at **Privacy (⌘6)** (`privacy.retentionDays`) | Set 1 day; check next day | Row is present at that address. Older transcripts swept | | | |
| ST-49 | Settings · Delete everything saved | Window open at **Privacy (⌘6)** (`privacy.deleteAll`) | Delete all (confirm) | Row is present at that address. Everything deleted; partial failure → S04 with list | | | |
| ST-50 | Settings · Run the Lab on this Mac | Window open at **Voice (⌘5)** (`voice.benchmark.run`) | Run | Row is present at that address. Lab runs; results shown | | | |
| ST-51 | Settings · The Lab's own panel (was a standalone window) | Window open at **Voice (⌘5)** (`LabPanelView(`) | Open | Row is present at that address. Panel inside Voice, no extra window | | | |
| ST-52 | Settings · Personal WER trend (was the Lab window's second tab) | Window open at **Voice (⌘5)** (`PersonalWERView(`) | Open | Row is present at that address. Trend graph from your corrections | | | |
| ST-53 | Settings · Voice enrollment (was its own window) | Window open at **Voice (⌘5)** (`voice.enrollment`) | Enroll / delete / "not you" | Row is present at that address. OB-15 behaviour; delete removes voiceprint | | | |
| ST-54 | Settings · Meeting capture | Window open at **Meetings (⌘2)** (`meetings.captureEnabled`) | Toggle off; try to start a meeting | Row is present at that address. Off: meeting capture unavailable with reason; on: MT-01 works | | | |
| ST-55 | Settings · Expose text in Chromium browsers (V5 Q2) | Window open at **Settings (⌘7) › General** (`settings.insertion.exposeChromiumText`) | Off; dictate in Chrome | Row is present at that address. Off: no AXEnhancedUserInterface set (context/caret may degrade); on: QF-02 | | | |
| ST-56 | Settings · Confirm in apps that hide their text — Screen Recording, off (V5 Q14) | Window open at **Settings (⌘7) › General** (`settings.insertion.confirmHiddenText`) | On | Row is present at that address. IN-18 / QF-14 | | | |
| ST-57 | Settings · Computer use page (V5 CU1) | Window open at **Settings (⌘7) › Computer use** (`ComputerUseSettingsPage(`) | Change enable, planner model (download/status), timeout, irreversible consent | Row is present at that address. Each takes effect on the next act turn (CU-21, CU-28); model download shows size by RAM | | | |
| ST-58 | Settings · Languages page (V5 LANG1) | Window open at **Settings (⌘7) › Languages** (`LanguagesSettingsPage(`) | Add/remove a language; set per-app language for WhatsApp; check cleanup model + speech models + word-list download | Row is present at that address. Route plan and per-app memory follow; cleanup model per language; downloads only on click | | | |

### 12.2 Rows added by V5 and the section pages

| ID | Area | Preconditions | Steps | Desired outcome | P/F | Notes | Evidence |
|---|---|---|---|---|---|---|---|
| ST-59 | Settings · Noise and echo reduction (C1/C1b) | Window open at **Voice (⌘5)** | Set Off / Apple / LocalVQE; dictate in noise | Row is present. Choice applied next turn; LocalVQE downloads on demand; CN-06/CN-07 | | | |
| ST-60 | Settings · Only react to my voice (K3) | Window open at **Voice (⌘5)** | Toggle with enrollment | Row is present. CN-18 | | | |
| ST-61 | Settings · Mic Modes… (K5) | Window open at **Voice (⌘5)** | Press with AirPods | Row is present. System mic-mode UI opens | | | |
| ST-62 | Settings · Voice test + meter | Window open at **Voice (⌘5)** | Run the voice test | Row is present. Meter moves; recovery row on failure; same capture graph as dictation (O1) | | | |
| ST-63 | Settings · Language row | Window open at **Voice (⌘5)** | Change spoken language | Row is present. Preview + note update; next dictation uses it | | | |
| ST-64 | Settings · Camera / lips row (LR1/LR3) | Window open at **Voice (⌘5)** | Turn on; choose Voice + lips / Lips only | Row is present. IN-20, IP-33, IP-34 | | | |
| ST-65 | Settings · Memory tier override (HW2) | Window open at **Settings (⌘7) › Models** | Pick a tier higher than this Mac's class | Row is present. Warning shown; residency plan follows | | | |
| ST-66 | Settings · AI cleanup model (D2) | Window open at **Settings (⌘7) › Models** | Download; toggle cleanup | Row is present. DS-30 behaviour; off → no cleanup stage in I3 | | | |
| ST-67 | Settings · Speech model install / cancel | Window open at **Settings (⌘7) › Models** | Install a model; cancel mid-way | Row is present. Cancel leaves no half model (1.7.11) | | | |
| ST-68 | Settings · Model stack | Window open at **Settings (⌘7) › Models** | Read the stack | Row is present. Lists ASR + VAD (Silero) + optional models with state | | | |
| ST-69 | Settings · Latch pause | Window open at **Settings (⌘7) › Shortcuts** | Change the latch pause | Row is present. Latched endpoint follows it | | | |
| ST-70 | Settings · Shortcut test | Window open at **Settings (⌘7) › Shortcuts** | Run the test | Row is present. Detects presses; fn conflict note (settings.fnConflict) when relevant | | | |
| ST-71 | Settings · MCP server (M23) | Window open at **Settings (⌘7) › Providers** | Toggle on/off | Row is present. MT-36 | | | |
| ST-72 | Settings · Channel (J5) | Window open at **Settings (⌘7) › Updates** | Switch release ↔ beta; Check now | Row is present. Offers the newest build on that channel that this macOS runs | | | |
| ST-73 | Settings · Install + restart guard (J5) | Window open at **Settings (⌘7) › Updates** | Install while dictating/recording | Row is present. Restart guard refuses to restart over active capture or unsaved drafts | | | |
| ST-74 | Settings · Version | Window open at **Settings (⌘7) › Updates** | Read | Row is present. Matches the DMG version | | | |
| ST-75 | Settings · Detected-meeting notifications | Window open at **Meetings (⌘2) › settings** | Toggle | Row is present. MT-09 notifies only when on | | | |
| ST-76 | Settings · Per-app don't-notify list | Window open at **Meetings (⌘2) › settings** | Add an app/browser | Row is present. MT-14 | | | |
| ST-77 | Settings · Reminder at start time | Window open at **Meetings (⌘2) › settings** | Toggle | Row is present. MT-15 | | | |
| ST-78 | Settings · Calendars | Window open at **Meetings (⌘2) › settings** | Choose calendars | Row is present. Only chosen calendars detected | | | |
| ST-79 | Settings · Auto-record calendar meetings (off) | Window open at **Meetings (⌘2) › settings** | Toggle | Row is present. MT-16 | | | |
| ST-80 | Settings · Save meeting recording (Always / 7 days / Never) | Window open at **Meetings (⌘2) › settings** | Change | Row is present. MT-05, MT-06 | | | |
| ST-81 | Settings · Perceived gender (on) | Window open at **Meetings (⌘2) › settings** | Toggle | Row is present. MT-26 | | | |
| ST-82 | Settings · Auto-export folder | Window open at **Meetings (⌘2) › settings** | Set folder | Row is present. MT-34 | | | |
| ST-83 | Settings · Post-meeting hook | Window open at **Meetings (⌘2) › settings** | Set command | Row is present. MT-35 | | | |
| ST-84 | Settings · Notes/Ask provider picker (M22) | Window open at **Meetings (⌘2)** | Pick each backend | Row is present. MT-31 | | | |
| ST-85 | Settings · Hard mute | Window open at **Privacy (⌘6)** | Toggle | Row is present. IP-28 | | | |
| ST-86 | Settings · Recordings retention 7/30/90/forever + disk cap (F3) | Window open at **Privacy (⌘6)** | Change; exceed cap | Row is present. Sweep and LRU behave | | | |
| ST-87 | Settings · Diagnostics export (Q13), include transcripts/audio | Window open at **Privacy (⌘6)** | Export with and without includes | Row is present. QF-13; includes only when ticked; preview shows contents | | | |
| ST-88 | Settings · Save dictation history | Window open at **Privacy (⌘6)** | Toggle off; dictate | Row is present. Off: no new history rows | | | |
| ST-89 | Settings · Public dictionaries (P-series) download | Window open at **Dictionary & Apps (⌘4)** | Download a list | Row is present. Notice + licence shown; list used | | | |
| ST-90 | Settings · Per-app contextual reading / word marks / style | Window open at **Dictionary & Apps (⌘4)** | Change for an app | Row is present. Context reading off → no field text read (I3 sheet); word marks off → none drawn | | | |
| ST-91 | Settings · Zero-edit counter (I2) | Window open at **Today (⌘1)** | After a day of use | Row is present. Status-menu row + Today card show a 7-day rate | | | |
| ST-92 | Settings · Timeline delete / delete all | Window open at **Today (⌘1)** | Delete a row; delete all | Row is present. Deleted after confirm; S04 on partial | | | |
| ST-93 | Settings · Notes page (N1) | Window open at **Notes (⌘3)** | Covered by §10 | Row is present. NT-10…NT-14 | | | |

Settings cases: 93 (58 indexed + 35 V5/section rows).

---

## 13. Recovery catalogue (RC)

Every entry of the 59-entry recovery catalogue (`Fixtures/design/design_copy.json` › `errors`,
`DESIGN.md` §7.1). Desired outcome = the exact headline, consequence and primary action, plus the
data rule. Case ID = `RC-` + catalogue ID.

| ID | Area | Preconditions | Steps | Desired outcome | P/F | Notes | Evidence |
|---|---|---|---|---|---|---|---|
| RC-P01 | Recovery · Permissions | Trigger: Microphone denied or revoked | Revoke Microphone (System Settings) and press ⟨key⟩ | “Microphone access is off” · “Recording cannot start. Nothing was typed.” · primary **Open Microphone settings** works. Data: No new audio | | | |
| RC-P02 | Recovery · Permissions | Trigger: Accessibility denied or revoked | Revoke Accessibility; dictate into TextEdit | “Allow VoicePlus to type” · “Dictation can be reviewed here; automatic insertion is unavailable.” · primary **Open Accessibility settings** works. Data: Keep completed text in recovery | | | |
| RC-P03 | Recovery · Permissions | Trigger: Legacy event tap lacks Input Monitoring | Legacy tap on; revoke Input Monitoring; press ⟨key⟩ | “The shortcut needs permission” · “Your shortcut won’t work until Input Monitoring is allowed.” · primary **Open Input Monitoring** works. Data: Keep existing drafts; request relaunch after grant | | | |
| RC-P04 | Recovery · Permissions | Trigger: Permission granted but process has stale grant | Grant Accessibility while running where macOS needs a relaunch | “Reopen VoicePlus to finish setup” · “The new permission takes effect after VoicePlus reopens.” · primary **Reopen VoicePlus** works. Data: Persist recovery first; block relaunch if save fails | | | |
| RC-K01 | Recovery · Shortcut | Trigger: Hotkey collision or registration failure | Settings › Shortcuts: bind ⟨key⟩ to a combo another app owns (e.g. ⌘Space) | “This shortcut is already in use” · “Your previous shortcut stays active.” · primary **Choose another shortcut** works. Data: Preserve prior binding | | | |
| RC-K02 | Recovery · Shortcut | Trigger: Missing key-up, lock, sleep or listener interruption | Latch, then lock the screen (⌃⌘Q) or sleep | “Dictation stopped” · “Recording is closed. Start again when ready.” · primary **Review recovered text** works. Data: Keep completed segments; label incomplete segment | | | |
| RC-K03 | Recovery · Shortcut | Trigger: Press shorter than 250 ms | Tap ⟨key⟩ < 250 ms | “Hold Right Control a little longer” · “Nothing was typed.” · primary **Try again** works. Data: Discard sub-threshold capture | | | |
| RC-K04 | Recovery · Shortcut | Trigger: Start while processing or session owned elsewhere | Release, then press ⟨key⟩ again while F0 Finishing | “Finishing your previous dictation” · “A second session has not started.” · primary **Wait or cancel** works. Data: Keep active turn | | | |
| RC-K05 | Recovery · Shortcut | Trigger: Hard mute is enabled | Menu › Mute microphone, press ⟨key⟩ | “VoicePlus is muted” · “The microphone stays closed until you unmute.” · primary **Unmute** works. Data: No capture | | | |
| RC-A01 | Recovery · Audio | Trigger: No input device | Select a USB mic in Voice, unplug it, press ⟨key⟩ | “No microphone found” · “Recording has not started.” · primary **Choose microphone** works. Data: No new audio | | | |
| RC-A02 | Recovery · Audio | Trigger: Device disappears during capture | Dictate with a USB mic/AirPods and unplug/remove mid-sentence | “Microphone disconnected” · “Recording stopped. Review any words already captured.” · primary **Choose microphone** works. Data: Keep decoded partial text; recover audio only if available | | | |
| RC-A03 | Recovery · Audio | Trigger: Input source cannot be selected or opened | Select an input another app holds exclusively (e.g. a DAW in exclusive mode) | “Couldn’t start this microphone” · “Nothing was recorded.” · primary **Choose microphone** works. Data: No new audio | | | |
| RC-A04 | Recovery · Audio | Trigger: Sample-rate or device-format mismatch | Use an audio interface set to an unusual rate (e.g. 192 kHz) in Audio MIDI Setup | “This microphone needs reconnecting” · “Recording could not start with this audio format.” · primary **Choose microphone** works. Data: Keep previous drafts | | | |
| RC-A05 | Recovery · Audio | Trigger: Recorder opens but receives no samples | Select a mic with its hardware mute on | “No audio is reaching VoicePlus” · “Check the selected input and its mute switch.” · primary **Test microphone** works. Data: Do not invent transcript | | | |
| RC-A06 | Recovery · Audio | Trigger: Samples arrive but no speech is detected | Hold ⟨key⟩ 3 s in silence | “No speech detected” · “Nothing was typed.” · primary **Try again** works. Data: Discard silence; retain no fake transcript | | | |
| RC-A07 | Recovery · Audio | Trigger: Too little usable audio for decoder | Hold ⟨key⟩ ~400 ms saying one syllable | “That was too short to transcribe” · “Nothing was typed. Hold the key through the sentence.” · primary **Try again** works. Data: No usable text | | | |
| RC-A08 | Recovery · Audio | Trigger: Quiet, clipped or noisy input | Dictate far from the mic / covered mic | “Your microphone sounds unclear” · “VoicePlus may miss some of your words.” · primary **Check microphone** works. Data: Capture continues; do not hide transcript | | | |
| RC-A09 | Recovery · Audio | Trigger: Another internal recorder owns input | Start a meeting recording, then start a second internal recorder (voice test) | “Microphone is in use” · “Another recording is using it right now.” · primary **Open active session** works. Data: Keep active recording | | | |
| RC-M01 | Recovery · Models | Trigger: No usable recognizer installed | Delete every speech model (Settings › Models), press ⟨key⟩ | “Install a speech model” · “Dictation is off until a model is ready.” · primary **Open Models** works. Data: No capture advertised as ready | | | |
| RC-M02 | Recovery · Models | Trigger: Download incomplete or scratch file missing | Quit during a model download; relaunch | “The speech model didn’t finish downloading” · “Dictation needs a complete model.” · primary **Download again** works. Data: Keep a previously working model | | | |
| RC-M03 | Recovery · Models | Trigger: Checksum or size verification fails | Corrupt a downloaded model file (append bytes) before verification | “The model download couldn’t be verified” · “The incomplete model will not be loaded.” · primary **Download again** works. Data: Quarantine invalid model; preserve working model | | | |
| RC-M04 | Recovery · Models | Trigger: Network or HTTP download failure | Turn Wi-Fi off mid-download | “Model download paused” · “Your connection interrupted the download.” · primary **Retry download** works. Data: Resume only verified resumable data | | | |
| RC-M05 | Recovery · Models | Trigger: Disk is full or files cannot be written | Fill the disk; start a model download | “Not enough space to finish setup” · “The current working model stays available.” · primary **Manage storage** works. Data: Keep existing usable files | | | |
| RC-M06 | Recovery · Models | Trigger: Model unsupported on this Mac | Pick a model not supported on this Mac (e.g. on an 8 GB Mac pick a 4B) | “This model can’t run on this Mac” · “Choose a model compatible with this system.” · primary **Choose another model** works. Data: Preserve current selection until replacement works | | | |
| RC-M07 | Recovery · Models | Trigger: Warm-up slow or loading fails | Start dictating right after launch while the model loads | “The speech model isn’t ready” · “The model is installed but hasn’t finished loading.” · primary **Retry loading** works. Data: Hold partial text only if it exists | | | |
| RC-M08 | Recovery · Models | Trigger: Model disappears during active use | Delete the active model folder while dictating | “The speech model became unavailable” · “Recording has stopped. Your completed words are kept.” · primary **Open Models** works. Data: Keep completed text; no silent model switch | | | |
| RC-T01 | Recovery · Transcription | Trigger: Decoder throws or returns invalid output | Hard to provoke: note if seen; diagnostics show decoder error | “Couldn’t finish this dictation” · “Review the words recovered so far, if any.” · primary **Review recovered text** works. Data: Keep valid partial text; Try again if none | | | |
| RC-T02 | Recovery · Transcription | Trigger: Final recognition exceeds deadline | Dictate 2 min latched then finish on a loaded Mac; watch for the 10 s option | “This is taking longer than usual” · “Recording has stopped. Nothing has been inserted yet.” · primary **Use available text** works. Data: Offer available text after 10 s; never insert late result twice | | | |
| RC-T03 | Recovery · Transcription | Trigger: Rewrite or provider refinement fails | Pin refinement/cleanup to a provider and block egress (kill switch) | “Cleanup is unavailable” · “The original transcript is still ready to review.” · primary **Use original text** works. Data: Preserve original and discard invalid rewrite | | | |
| RC-T04 | Recovery · Transcription | Trigger: Confidence metadata unavailable | Use a backend without confidence (e.g. Apple Speech route) | “Confidence isn’t available for this result” · “Unmarked words haven’t been checked.” · primary **Review text** works. Data: Preserve transcript; no invented confidence | | | |
| RC-T05 | Recovery · Transcription | Trigger: Rewrite changes uncertain word alignment | Dictate with cleanup on and an uncertain word that cleanup rewrites | “Review this phrase” · “VoicePlus isn’t sure about part of this phrase.” · primary **Review phrase** works. Data: Keep source-to-final provenance | | | |
| RC-D01 | Recovery · Delivery | Trigger: Focus, selection or target content changes | Hold-dictate, ⌘Tab away before release | “Destination changed — text held” · “Nothing was typed into the new destination.” · primary **Insert here** works. Data: Keep final text and uncertainty spans | | | |
| RC-D02 | Recovery · Delivery | Trigger: No editable target or read-only field | Focus a read-only web text | “Choose a text field” · “Your words are ready here.” · primary **Copy text** works. Data: Keep final text; explicit insertion only | | | |
| RC-D03 | Recovery · Delivery | Trigger: Password or secure field | Focus a password field and press ⟨key⟩ | “VoicePlus is paused in this field” · “No dictation is inserted into secure fields.” · primary **Dismiss** works. Data: No new secure-field capture; prior draft remains private | | | |
| RC-D04 | Recovery · Delivery | Trigger: App excluded by user or never-inject policy | Set Never inject for the app; dictate | “Dictation is off in this app” · “Your app rule prevents insertion.” · primary **Review app rule** works. Data: Keep already-completed ordinary dictation | | | |
| RC-D05 | Recovery · Delivery | Trigger: All insertion methods fail before writing | Dictate into an app that refuses AX and paste (e.g. a secure input app) | “Couldn’t insert your text” · “Your text is kept here.” · primary **Copy text** works. Data: Keep final text; retry only after safe target check | | | |
| RC-D06 | Recovery · Delivery | Trigger: Readback unavailable after insertion attempt | Dictate into a field with no readback after the settle window (DS-10 conditions) | “Couldn’t confirm insertion” · “Check the field before trying again.” · primary **Check text** works. Data: Keep record marked unconfirmed; never auto-retry | | | |
| RC-D07 | Recovery · Delivery | Trigger: Readback shows partial or mismatched insertion | Dictate 20 chars into a maxlength-10 web input | “Only part may have been inserted” · “Check the destination to avoid duplicate text.” · primary **Review result** works. Data: Keep original and readback separately | | | |
| RC-D08 | Recovery · Delivery | Trigger: Clipboard fallback blocked or clipboard changes | Use a clipboard manager that rewrites the clipboard during insertion | “Couldn’t copy your text” · “Your words are still available for manual selection.” · primary **Select text** works. Data: Keep draft; restore clipboard only if still owned | | | |
| RC-D09 | Recovery · Delivery | Trigger: Cannot locate trustworthy word rectangles | Dictate into a canvas app (Figma) with confidence marks on | “Word marks aren’t available in this app” · “The text can be inserted, but review marks stay in VoicePlus.” · primary **Review words** works. Data: Preserve spans in history; no floating inaccurate marks | | | |
| RC-D10 | Recovery · Delivery | Trigger: Destination changes before correction or undo | Open a correction/undo, then edit the field before applying | “The text has changed” · “Your correction has not replaced anything.” · primary **Copy correction** works. Data: Keep proposed correction; invalidate stale range | | | |
| RC-D11 | Recovery · Delivery | Trigger: New hotkey while text is held | Leave a held dictation; press ⟨key⟩ again | “You have text waiting” · “Resolve or save this draft before a new dictation.” · primary **Review held text** works. Data: Never overwrite held draft | | | |
| RC-S01 | Recovery · Storage | Trigger: History or timeline read fails | Make the history DB unreadable (chmod 000 the db in App Support) and open Today | “History can’t be read” · “Other working sections remain available.” · primary **Try again** works. Data: Do not clear store or claim it is empty | | | |
| RC-S02 | Recovery · Storage | Trigger: Setting, dictionary or app rule save fails | Make the settings/dictionary store read-only; change a setting | “Changes weren’t saved” · “Your previous setting is still active.” · primary **Try again** works. Data: Keep entered value and indicate unsaved state | | | |
| RC-S03 | Recovery · Storage | Trigger: Draft or transcript persistence fails | Make the drafts folder read-only; leave a held draft | “This text hasn’t been saved” · “Keep this window open until you copy it.” · primary **Copy text** works. Data: Keep in memory; do not claim crash-safe recovery | | | |
| RC-S04 | Recovery · Storage | Trigger: Deletion succeeds only for some items | Lock one recording file (chflags uchg) then Delete all | “Some items couldn’t be deleted” · “The other items were deleted.” · primary **Retry deletion** works. Data: Preserve accurate count and failure list | | | |
| RC-S05 | Recovery · Storage | Trigger: App quits or crashes during capture | Force-quit VoicePlus (Activity Monitor) while latched; relaunch | “An unfinished recording was found” · “Only what was saved before VoicePlus closed can be recovered.” · primary **Recover** works. Data: Show retained duration and location; never imply missing audio exists | | | |
| RC-N01 | Recovery · Services | Trigger: Remote provider offline or timeout | Pin Ask to a cloud provider; disconnect Wi-Fi | “The service isn’t responding” · “Local transcription still works when its model is ready.” · primary **Retry service** works. Data: Keep local result; no silent cloud fallback | | | |
| RC-N02 | Recovery · Services | Trigger: Credentials rejected | Enter an invalid API key for a provider; use it | “Reconnect this service” · “The current request was not completed.” · primary **Reconnect** works. Data: Keep local drafts; never show API key in error | | | |
| RC-N03 | Recovery · Services | Trigger: Rate limit, quota or billing rejection | Use a provider key with no quota/billing | “This service is temporarily unavailable” · “The provider isn’t accepting requests right now.” · primary **Use local option** works. Data: Keep local transcript; no automatic paid upgrade | | | |
| RC-N04 | Recovery · Services | Trigger: Malformed, unsupported or disabled provider response | Point a provider at a local server returning malformed JSON (or disable its capability) | “This service couldn’t complete the request” · “The original text has been preserved.” · primary **Review service settings** works. Data: No partial rewrite replaces original | | | |
| RC-X01 | Recovery · Meetings | Trigger: System audio or Calendar permission absent | Deny Calendar / system audio; start a meeting | “Meeting setup needs attention” · “Calendar or system audio access is off. Microphone-only recording may still work.” · primary **Review permissions** works. Data: Keep available mic track; label missing track | | | |
| RC-X02 | Recovery · Meetings | Trigger: Recording interrupted or transcript unreadable | Force-quit during a meeting recording; relaunch | “This meeting needs recovery” · “Saved audio and text are kept.” · primary **Recover meeting** works. Data: Preserve saved audio/text; never fabricate speaker turns | | | |
| RC-X03 | Recovery · Voice | Trigger: Enrollment too short or speaker model unavailable | Stop enrollment after 5 s | “Couldn’t finish voice setup” · “Hold-to-talk still works; speaker filtering stays off.” · primary **Try voice setup again** works. Data: Keep prior enrollment until replacement succeeds | | | |
| RC-X04 | Recovery · Dictionary | Trigger: Contacts denied or import malformed | Deny Contacts; import names | “Couldn’t import these words” · “Existing dictionary entries are unchanged.” · primary **Review import** works. Data: Preview valid entries and list rejected rows | | | |
| RC-X05 | Recovery · Sync | Trigger: Pairing mismatch, bad key or tampered payload | Pair with a wrong passphrase / tamper the exported payload | “Devices couldn’t be paired safely” · “Nothing from this transfer was applied.” · primary **Pair again** works. Data: Keep local data; do not weaken verification | | | |
| RC-X06 | Recovery · Sync | Trigger: Peer offline or concurrent edits conflict | Edit the same persona on both paired Macs offline; reconnect | “Sync needs attention” · “Local dictation continues. Review conflicting edits.” · primary **Review sync** works. Data: Keep both versions until resolved | | | |
| RC-X07 | Recovery · System | Trigger: Update fails or is interrupted | Cut Wi-Fi during an update download | “The update didn’t finish” · “Keep using the installed version.” · primary **Retry update** works. Data: Do not discard drafts or replace working app early | | | |
| RC-X08 | Recovery · System | Trigger: Unexpected unmapped error | Any unmapped error seen during testing (note it) | “VoicePlus couldn’t finish this step” · “Any text captured so far is kept. Check the result before trying again.” · primary **Open recovery** works. Data: Preserve available data; technical details in diagnostics | | | |

Recovery cases: 59.

---

## 14. Accessibility (AX)

| ID | Area | Preconditions | Steps | Desired outcome | P/F | Notes | Evidence |
|---|---|---|---|---|---|---|---|
| AX-01 | VoiceOver · pill | VO on | Dictate; VO to the pill in F1/F2/H0/D2 | State announced; actions reachable and named | | | |
| AX-02 | VoiceOver · window | VO on | Navigate sidebar, each section, Settings subpages | Every control labelled; order logical | | | |
| AX-03 | VoiceOver · onboarding | VO on, R3 | Full onboarding | Completable by VO only | | | |
| AX-04 | Keyboard-only · window | No mouse | Tab/⇧Tab, ⌘1–⌘7, ⌘F, ⌘, | All reachable; focus ring visible | | | |
| AX-05 | Keyboard-only · pill (Q8) | — | Tab into the pill during F1 | Focus only via keyboard navigation; dwell pauses while focused and resumes after; focus cleared each turn | | | |
| AX-06 | Keyboard-only · recovery sheet | A held dictation | Open Review from menu; operate with keyboard | All three actions reachable | | | |
| AX-07 | Increase Contrast · window | On | Walk every section | Text/borders meet contrast | | | |
| AX-08 | Increase Contrast · pill | On | Walk pill states | As HU-12 | | | |
| AX-09 | Reduce Motion · pill | On | Dictate; screen-record | No reel spin/tape flight; state changes by fades/static per DESIGN §6.1 | | | |
| AX-10 | Reduce Motion · onboarding | On | Onboarding | No motion except essential | | | |
| AX-11 | Notch / no-notch | R1 and R5 | Idle + dictate | HU-03 / HU-04 hold | | | |
| AX-12 | External monitor | R2 | Window + pill on external | Correct scale; pill on the work's display | | | |
| AX-13 | Larger text / Display zoom | Display "Larger Text" | Open window | No clipped labels | | | |
| AX-14 | Dark / light | Toggle appearance | Window + pill | Both themes correct | | | |

---

## 15. The 16 §Q fixes (QF)

| ID | Area | Preconditions | Steps | Desired outcome | P/F | Notes | Evidence |
|---|---|---|---|---|---|---|---|
| QF-01 | Q1 newlines never send | Claude, Slack, WhatsApp, Cursor, Sheets | Dictate two paragraphs in each | Nothing ever submitted; ⇧↩ in Electron/Chromium chat, ⌥↩ in Sheets cells | | | |
| QF-02 | Q2 Electron/Chromium text exposed | Claude, Slack, VS Code; Chrome with "Expose text in Chromium browsers" on | Dictate; open I3 sheet | Caret and field text readable; context present; turning the switch off stops Chromium exposure | | | |
| QF-03 | Q3 settle before judging | Slow app (Docs) | Dictate | No false "Couldn't confirm"; settle ms recorded in diagnostics (≤ 400 ms) | | | |
| QF-04 | Q4 neutral landing | Unreadable field (Figma canvas, Claude) | Dictate | Plain "Inserted in <app>" without ✓, auto-clears; sticky warning only when settled readback shows text absent | | | |
| QF-05 | Q5 ribbon independent of verification | Apps where verification fails | Dictate | Tape still flies to caret → text-marker → element → window rung | | | |
| QF-06 | Q6 pill follows the work | R2: app on external display, mouse on built-in | Dictate | Pill on the caret's display; re-chosen every turn | | | |
| QF-07 | Q7 "on screen" per display | R2 | Full-screen app on one display | Chin suppression judged on the pill's chosen display only | | | |
| QF-08 | Q8 self-healing pauses | F1 preview | Hover then leave; Tab focus; leave pointer resting | Dwell resumes; a cause-less pause > 2 s dropped and logged | | | |
| QF-09 | Q9 Hide Others | Any app | ⌥⌘H in another app while pill visible | Pill and chin survive | | | |
| QF-10 | Q10 live mic status | IN-11, IN-12 | — | Status re-read on activation, before refusal, on TCC change | | | |
| QF-11 | Q11 Input Monitoring re-arm | IN-28 | — | Tap re-created; "Listening again" | | | |
| QF-12 | Q12 pause copy | Empty draft | Hold ⟨key⟩ silent, release | "Nothing was typed."; pause lines per "Pause states — simplified" | | | |
| QF-13 | Q13 persisted diagnostics | After 20 turns | Privacy › Diagnostics › Export (save panel) | Save panel works; file has placement, orderFront/Out reasons, dwell pause/resume (reason + pointer + frame), landing verdicts, decisions; no transcript text unless opted in; 7-day sweep | | | |
| QF-14 | Q14 OCR confirmation | Screen Recording granted; switch on | Dictate into Docs/Figma | OCR caret band confirms; off by default | | | |
| QF-15 | Q15 CoreML crash hardening | Refinement on (OA-04) | 30 rapid dictations, some cancelled mid-refinement | No crash; late refinement never double-inserts | | | |
| QF-16 | Q16 LaunchServices | OA-01 done | `lsregister -dump \| grep -i voiceplus`; open a voiceplus URL/Spotlight | Only `/Applications` copy registered and launched | | | |

---

## 16. Model / data / hardware gates (GT)

Measurement cases the build agents could not run (datasets, models, disk, real Macs). Each needs
its owner action first; then ask a build agent to run the gate and attach the `Lab/results` file.

| ID | Area | Preconditions | Steps | Desired outcome | P/F | Notes | Evidence |
|---|---|---|---|---|---|---|---|
| GT-01 | V4 qwenRefinement re-validation | OA-04 | Run V4 re-validation for qwenRefinement | Verdict recorded in DECISIONS.md | | | |
| GT-02 | B1 boosting gate | OA-05, OA-07 | Earnings-22 + MUSAN eval | Entity recall up, false insertions ≤ +0.5 pp, WER not worse | | | |
| GT-03 | B5 Ultra/Redux ranking | OA-08, OA-09, OA-05 | Eval v3 vs Ultra vs Redux | Default switched only if better; Redux ANE compile checked on M-series | | | |
| GT-04 | C1 VP-IO gate | OA-05, OA-06 | VOiCES + MUSAN | Default stays Off unless VP wins | | | |
| GT-05 | C1b LocalVQE gate | OA-05, OA-06, OA-22 | Same vs VP | Choose default; far-end reference via O1 | | | |
| GT-06 | V3 MUSAN noise mixing | OA-05 | `mix` sets at 20/10/5/0 dB | Noisy sets on disk | | | |
| GT-07 | V1 Svarah baseline | OA-08 | Eval | baselines.json updated | | | |
| GT-08 | D1 ITN on LibriSpeech-PC | OA-10 | Eval numeric subset | < 0.5 pp regression | | | |
| GT-09 | K8 prosody punctuation | OA-10 | PunctuationF1 gate; then wire engine audio → ProsodyCues | Flag stays off until F1 gain | | | |
| GT-10 | O4/L4 arbiter accuracy | OA-11, OA-23 + T1 scripted 150 command lines | Kev on command lines + AMI ignore set | ≥ 90 % owner on commands; ≥ 95 % ignore on AMI | | | |
| GT-11 | L6 decide set | OA-11 | Build decide-set from AMI/NOTSOFAR | Labels owner-confirmed | | | |
| GT-12 | M9 WeSpeaker vs CAM++ | OA-11, OA-12, OA-18 | DER on VoxConverse/AMI | Default by DER and licence | | | |
| GT-13 | G1 Srota vs base | OA-13, OA-16 | MUCS/HiACC WER | Ship Srota if better; replace the `.srota` placeholder | | | |
| GT-14 | LR6 lips / fused | OA-14, OA-17, OA-05 | `lrs3Eval` | WER recorded; fused default only if it helps | | | |
| GT-15 | C4 Smart Turn | OA-15 | Endpoint latency vs silence timeout on V1 | Earlier endpoint without cutting sentences | | | |
| GT-16 | CU2 CUA-S1 80 % fixture | OA-19 | Run fixture on the real model | ≥ 80 % | | | |
| GT-17 | P6 IndicXlit | OA-20 | Transliteration accuracy | Better than rule-based | | | |
| GT-18 | P7 GLiNER2 / P4 phonemes | OA-21 | Entity typing + phoneme path on fixture | Gains recorded | | | |
| GT-19 | C5 EOU 320 preview WER | OA-22 | V1 preview-WER | Default 320 only if better | | | |
| GT-20 | D2 cleanup model eval | Cleanup GGUF | V1 cleanup gate; p95 ≤ 500 ms on M2 Pro | Model pick confirmed | | | |
| GT-21 | B3 replay latency | — | Measure N-best replay on the owner's Mac | ~60 ms claimed vs ~330 ms measured here — record | | | |
| GT-22 | V4 previewBackend / mic bounds | OA-05 | Re-measure | Decisions confirmed | | | |
| GT-23 | A3 per-flag V1 measurement | Datasets | Each flag's kill criterion | Verdicts executed | | | |
| GT-24 | H2 gatekeeper threshold re-check | OA-11 | On V1 decide data | 0.9 threshold confirmed | | | |
| GT-25 | L5 ambient CPU in-app | Listen & note, 30 min idle + speech | Activity Monitor CPU + Energy | Near the offline 0.11 % idle / 1.99 % speech | | | |
| GT-26 | HW2 memory tiers | R4 8 GB and ≥ 24 GB | First launch on each | Right tier; Settings › Models override + warning work; 4B only on ≥ 24 GB | | | |
| GT-27 | HW1/D5 residency + prewarm | — | Dictate after 6 min idle; watch unified log | Idle unload at 5 min; prewarm on key-down; timed-out load ends the pass and next press retries | | | |
| GT-28 | K19 pill retention | Normal use for a day | If the pill stays up ~27 s after landing, export diagnostics at once | Retention backstop clears it ≤ release + 1.5 s; TurnDiagnostics show the cause | | | |
| GT-29 | J2 CI | OA-03 | Run workflow | Green; test log artifact | | | |
| GT-30 | J4 notarized DMG | OA-02 | `spctl -a -vv /Applications/VoicePlus.app` | "accepted, source=Notarized Developer ID" | | | |

---

## 17. Coverage index — every partial / needs-hardware item → cases

| V5 item | Status at T1 | Cases |
|---|---|---|
| Q1 | done; hardware | DS-05, DS-07, DS-08, DS-14, DS-16, QF-01 |
| Q2 | done; hardware | DS-09, QF-02 |
| Q3 | done | QF-03 |
| Q4 / Q5 | done; live AX rungs | DS-10, QF-04, QF-05 |
| Q6 / Q7 | done; two displays | CN-16, CN-17, QF-06, QF-07 |
| Q8 | done; Tab/VoiceOver | AX-05, QF-08 |
| Q9 | done | QF-09 |
| Q10 / Q11 | done; real TCC / tap | IN-11, IN-12, IN-28, QF-10, QF-11 |
| Q12 | done | QF-12 |
| Q13 | partial → completed in W8 (landing + dwell + decisions recorded); save panel | QF-13 |
| Q14 | done; Screen Recording | IN-18, DS-15, DS-20, QF-14 |
| Q15 | done | QF-15 |
| Q16 | **blocked [owner]** | OA-01, QF-16 |
| K19 | partial (27 s not reproduced) | GT-28 |
| K21 | done (+ verify in Engine prepare, 0bc07a5); row look | OA-04, ST refinement rows |
| V3 / V4 / A3 / H2 | partial (datasets) | GT-01, GT-06, GT-22, GT-23, GT-24 |
| V1 Svarah | gated → owner | OA-08, GT-07 |
| C6 (+K17) | done; fresh-install "vad: using silero" log | IN-01 (check unified log), GT-27 |
| C1 / C1b | partial | CN-06, CN-07, GT-04, GT-05 |
| C3 | done; real SCO | CN-09, CN-11 |
| C4 | partial (CoreML export) | OA-15, CN-20, GT-15 |
| C5 | partial | CN-21, GT-19 |
| K2 / K4 | done; real room | CN-03, CN-19, NT-09 |
| F3 | done | CN-24, MT-07, DS-23 |
| B1 | partial (Earnings-22/MUSAN) | DS-29, GT-02 |
| B5 | partial | GT-03 |
| B3 | done; replay latency | GT-21 |
| D1 + K7 | done; pill vs landed | CN-26, GT-08 |
| HW1 | partial (consumers register) | GT-27 |
| HW2 | done; 8/24 GB Macs | GT-26 |
| HW3 | partial → chip wired in W8 (5cffc02); real pressure | CN-23 |
| D5 | done (+ timeout fixes); real latency | GT-27 |
| D2 | partial (model eval) | DS-30, GT-20 |
| I3 | done; sheet UI manual | §0.3, DS-03, DS-09 |
| B2+E1 / E2 / E3 / E5 / E6 | done; real apps | DS-03, DS-06, DS-09, DS-16–DS-24 |
| P1–P7 | partial (P4 phoneme, P6 IndicXlit, P7 GLiNER2) | OA-20, OA-21, DS-29, IP-30, GT-17, GT-18 |
| F4 | done; real pairing | OA-26, ST Sync rows, RC-X05, RC-X06 |
| O1 | done (+ meeting claim W8); one HAL client + mic indicator | MT-18, OC-01, OC-05, CN-14 |
| O2 / O3 | done; real-audio alignment | OC-*, IP-26 |
| O4 + O5 + L4 | done; ≥ 90 % owner + AMI | OA-23, IP-20…IP-27, OC-16, GT-10 |
| L1 / L2 / L3 | done | IP-18…IP-25 |
| L5 | done offline; live in-app | GT-25 |
| L6 | partial (AMI/NOTSOFAR) | OA-11, GT-11 |
| K3 | done | CN-18 |
| N1 / N3 / N4 | done; SwiftUI look / migration | NT-10…NT-14, IN-06 |
| N2 | partial → remaining routes wired in W8 (d126fcb) | NT-01…NT-09 |
| M1–M5, M14, M12, M6, M7, M8, M10, M13 | done; real meetings | MT-01…MT-08, MT-19…MT-27 |
| M9 | partial (DER, CAM++ licence) | OA-18, GT-12 |
| M11 | partial (OCR fallback, LR1 lips not wired) | MT-24 |
| M-d | done (+ fixes c6b4d39); CoreAudio/AX/EventKit | MT-09…MT-17, MT-35 |
| M16–M23 | done | MT-28…MT-36 |
| CU1 / CU8 / CU4 / CU6 / CU7 / CU9 / H4 | done; real planner | CU-01…CU-23, CU-26…CU-30, IP-15 |
| CU2 | partial (FluidUse pin) | OA-19, CU-24, CU-25, GT-16 |
| LANG1 | partial → finished in W8 (ce9d26f): cleanup by language, per-language P-series, per-app memory, Languages page | OB-12…OB-14, IP-29, IP-31, IP-32, ST Languages rows |
| LANG2 / G3 | done; IndicXlit quality | IP-29, IP-30 |
| G1 | partial (Srota conversion) | OA-16, IP-31, GT-13 |
| G2 | done; real model | IP-32 |
| LR1 / LR3 / LR5 | done; camera | IN-20, IN-21, IP-33 |
| LR2 | partial (Auto-AVSR) | OA-17, IP-34, GT-14 |
| K5 | done; wideband re-measure | CN-13 |
| K8 | partial | GT-09 |
| K16 | carried | CN-08…CN-12 |
| K23 | carried | HU-01…HU-12 |
| J5 | done (W8) | IN-07, IN-08, ST Updates rows, RC-X07 |
| J2 | done, manual-only; runner/account → owner | OA-03, GT-29 |
| J4 | **blocked [owner]** | OA-02, GT-30 |
| I4 | done (source audit) | ST Privacy egress rows |
