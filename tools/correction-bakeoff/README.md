# Context-rewrite bake-off

Runs the owner's real dictation failures (plus must-not-change controls) through candidate LLMs
on OpenRouter, with the context the app would send (app, text before cursor, screen terms,
uncertain words, recogniser alternates). Measures pass rate, time to first token and total time
from this Mac. See `VoicePlus_ContextWriter_Plan.md` §6.

```bash
export OPENROUTER_API_KEY=sk-or-...        # or: echo sk-or-... > ~/.config/openrouter/key
python3 tools/correction-bakeoff/bakeoff.py --repeat 3 --out /tmp/bakeoff.json
python3 tools/correction-bakeoff/bakeoff.py --models deepseek/deepseek-v4.1-flash --reasoning none
```

- `cases.jsonl` holds 16 failures to fix and 8 controls.
  - **Failures** are mostly real turns from `voiceplus.sqlite`, 2026-10-03 to 10-07: a16z, Phase 2, Finish dictation, subagents, Qwen 4B, and the damage the booster did.
  - **Controls** are clean dictations, prompt injection, and distractor terms on screen.
  - **Scoring** is mechanical: `must_contain`, `must_not_contain`, and `unchanged`.
- `system_prompt.txt` is the candidate rewrite prompt. It is deliberately neutral: no example from the cases appears in it. An earlier draft quoted "a sixteen z = a16z" and inflated the local results.
- **Local baseline (2026-10-07):** `Qwen3.5-4B-Q4_K_M` through the app's `llama.framework` on the M2 Pro, same prompt and cases. It fixed 4 of 16, kept 8 of 8 controls, at p50 1,053 ms and p90 1,544 ms.
- **Cost:** the run costs cents. Each case is about 500 tokens in and 60 out.
