#!/usr/bin/env python3
"""Regenerate `Fixtures/context-magic/manifest.json` from `cases.jsonl`.

The bake-off (`bakeoff.py`) and the Lab `context-magic` suite (`Lab/Harness/ContextMagicSuite.swift`)
score the same cases; this script is the one place the translation lives, so the two cannot drift.

    python3 tools/correction-bakeoff/export_manifest.py            # writes the manifest
    python3 tools/correction-bakeoff/export_manifest.py --check    # exit 1 when the committed file is stale

Each case becomes a `ContextPacket` (Shared/Writer/ContextPacket.swift) plus an `expect` block:

- `app`      → `destination` (profile id, app name, bundle id, surface kind) via APP_PROFILES below.
- `before`   → `textBefore`.
- `screen`   → `screenTerms` (nearest the caret first, as listed).
- `heard`    → `heard.raw` (the [[ ]] marks removed) and `heard.words`; a word that was marked
               [[uncertain]] gets confidence 0.3, the rest 0.95 (threshold 0.5 — `isUncertain`).
- `alt`      → per-word `alternates` ("A -> B; C D -> E F": the replacement is attached to the first
               heard word of the source span; the recogniser's alternates are strings, phrases allowed).
- `recording`/`wav` → where the audio is. Recordings are the owner's private clips under
               ~/Library/Application Support/VoicePlus/Recordings (NOT committed); `wav` is a path
               under Fixtures/audio for synthetic committed clips. Stamps come from RECORDINGS.
- `heard`    → the raw text, for runs without the audio (`lab run --suites context-magic --text-only`).
- `kind`     → `control` for the must-not-change cases (ids `ctrl-*`), otherwise `fix`.
"""
import argparse, json, re, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
CASES = HERE / "cases.jsonl"
MANIFEST = ROOT / "Fixtures" / "context-magic" / "manifest.json"

UNCERTAIN_CONFIDENCE = 0.3
CONFIDENT_CONFIDENCE = 0.95

# The bake-off's free-text `app` → destination record (plan §2.1 / §3 profile ids).
APP_PROFILES = {
    "Claude desktop (chat message box)": ("ai.chat", "Claude", "com.anthropic.claudefordesktop", "chatComposer"),
    "Claude desktop (Claude Code session)": ("ai.agentCLI", "Claude", "com.anthropic.claudefordesktop", "chatComposer"),
    "ChatGPT Codex (prompt box)": ("ai.chat", "Codex", "com.openai.codex", "chatComposer"),
    "Slack (message)": ("chat.message", "Slack", "com.tinyspeck.slackmacgap", "chatComposer"),
    "Mail (email body)": ("email.body.reply", "Mail", "com.apple.mail", "emailBody"),
    "Terminal (Warp) command prompt": ("shell", "Warp", "dev.warp.Warp", "terminal"),
}

# Recording stamps for the real turns (investigation 2026-10-06 §1/§5; the rest found by transcript
# in the Recordings sidecars). A case without a stamp runs from `heard` text only.
RECORDINGS = {
    "qwen4b-boosted": "2026-10-07-004102-993",   # 00:41 IST, Claude: "Queen four B ... polishing Code"
    "qwen4b-raw": "2026-10-07-004102-993",       # same audio, pre-boost text
    "a16z-codex": "2026-10-06-233509-411",
    "a16z-claude": "2026-10-07-003305-888",
    "a16z-thread": "2026-10-06-233509-411",      # same audio as a16z-codex, synthetic thread
    "phase2-till": "2026-10-06-230656-611",      # "till face two"
    "phase2-faze": "2026-10-06-230643-188",      # "El says two" / "L FaZe Two"
    "finish-dictation": "2026-10-04-002438-245",
    "subagents-2": "2026-10-04-003509-851",
    "adv-add": "2026-10-06-101721-327",
    "invest-dial": "2026-10-03-225834-252",
    "ctrl-question": "2026-10-06-160605-216",
    "ctrl-plan": "2026-10-06-230612-207",
    "ctrl-unanimous": "2026-10-06-215142-754",
    "ctrl-icon": "2026-10-06-215809-683",
    "ctrl-articles": "2026-10-06-102040-613",
}

MARK = re.compile(r"\[\[(.*?)\]\]")


def heard_words(marked: str, alt: str | None) -> tuple[str, list[dict]]:
    """Split the bake-off's marked text into `heard.words`; returns (raw, words)."""
    tokens = []
    for tok in marked.split():
        m = MARK.fullmatch(tok)
        # A mark can wrap a word with trailing punctuation: "[[z]]." → uncertain "z."
        inner = MARK.sub(r"\1", tok)
        tokens.append({"text": inner, "confidence": UNCERTAIN_CONFIDENCE if (m or "[[" in tok) else CONFIDENT_CONFIDENCE,
                       "alternates": []})
    raw = " ".join(t["text"] for t in tokens)
    for pair in (alt or "").split(";"):
        if "->" not in pair:
            continue
        src, dst = (s.strip() for s in pair.split("->", 1))
        src_words = src.split()
        for i in range(len(tokens) - len(src_words) + 1):
            window = [strip_punct(t["text"]) for t in tokens[i:i + len(src_words)]]
            if [w.lower() for w in window] == [strip_punct(w).lower() for w in src_words]:
                if dst not in tokens[i]["alternates"]:
                    tokens[i]["alternates"].append(dst)
                break
        else:
            sys.exit(f"alt source '{src}' not found in heard text: {marked!r}")
    return raw, tokens


def strip_punct(w: str) -> str:
    return re.sub(r"^[^\w*]+|[^\w*]+$", "", w)


def packet(c: dict) -> dict:
    profile, app, bundle, surface = APP_PROFILES[c["app"]]
    raw, words = heard_words(c["heard"], c.get("alt"))
    return {
        "mode": "transcribe",
        "destination": {"profileID": profile, "appName": app, "appBundleID": bundle, "surfaceKind": surface, "fields": {}},
        "textBefore": c.get("before", ""),
        "textAfter": "",
        "thread": [],
        "screenTerms": list(c.get("screen", [])),
        "vocabulary": [],
        "recentDictations": [],
        "heard": {"raw": raw, "words": words},
        "isSecure": False,
    }


def export_case(c: dict) -> dict:
    p = packet(c)
    out = {"id": c["id"], "kind": "control" if c["id"].startswith("ctrl-") else "fix", "source": c.get("source", "")}
    if c["id"] in RECORDINGS:
        out["recording"] = RECORDINGS[c["id"]]
    out["heard"] = p["heard"]["raw"]
    out["packet"] = p
    out["expect"] = {"must_contain": list(c.get("must_contain", [])),
                     "must_not_contain": list(c.get("must_not_contain", [])),
                     "unchanged": bool(c.get("unchanged", False))}
    return out


def build() -> dict:
    cases = [json.loads(l) for l in CASES.read_text().splitlines() if l.strip()]
    ids = [c["id"] for c in cases]
    assert len(ids) == len(set(ids)), "duplicate case ids"
    return {"version": 1, "suite": "context-magic",
            "generatedFrom": "tools/correction-bakeoff/cases.jsonl via export_manifest.py",
            "cases": [export_case(c) for c in cases]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="exit 1 when the committed manifest differs")
    ap.add_argument("--out", default=str(MANIFEST))
    a = ap.parse_args()
    text = json.dumps(build(), indent=2, ensure_ascii=False) + "\n"
    target = Path(a.out)
    if a.check:
        if not target.exists() or target.read_text() != text:
            sys.exit(f"{target} is stale; run export_manifest.py")
        print(f"{target} is up to date")
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)
    n = len(json.loads(text)["cases"])
    print(f"wrote {target} ({n} cases)")


if __name__ == "__main__":
    main()
