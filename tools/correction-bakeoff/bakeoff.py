#!/usr/bin/env python3
"""Context-rewrite bake-off: the owner's real dictation failures through candidate LLMs.

Stdlib only. Streams each request so time-to-first-token and total time are measured
from this Mac (what the app would see).

    export OPENROUTER_API_KEY=...            # or put the key in ~/.config/openrouter/key
    python3 tools/correction-bakeoff/bakeoff.py                   # default model set
    python3 tools/correction-bakeoff/bakeoff.py --models google/gemini-3.5-flash-lite anthropic/claude-haiku-4.5
    python3 tools/correction-bakeoff/bakeoff.py --repeat 3 --out results.json

Scoring per case: every `must_contain` present, no `must_not_contain`, and for `unchanged`
controls the output equals the heard text (ignoring case, punctuation and [[ ]] marks).
"""
import argparse, json, os, re, statistics, sys, time, urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent

DEFAULT_MODELS = [
    "deepseek/deepseek-v4.1-flash",
    "google/gemma-4-26b-a4b-it",
    "openai/gpt-6-luna",
    "mistralai/mistral-small-2603",
    "nvidia/nemotron-3.5-lightning",
    "qwen/qwen3.7-flash",
    "z-ai/glm-5.3-flash",
    "xiaomi/mimo-v2.6-flash",
    "qwen/qwen3.8-omni-flash",
]

SYSTEM = (HERE / "system_prompt.txt").read_text()


def key() -> str:
    k = os.environ.get("OPENROUTER_API_KEY")
    if not k:
        p = Path.home() / ".config/openrouter/key"
        if p.exists():
            k = p.read_text().strip()
    if not k:
        sys.exit("Set OPENROUTER_API_KEY or write the key to ~/.config/openrouter/key")
    return k


def user_message(c: dict) -> str:
    lines = [f"APP: {c['app']}", f"TEXT BEFORE CURSOR: {c.get('before', '')}",
             f"SCREEN: {', '.join(c.get('screen', []))}", f"HEARD: {c['heard']}"]
    if c.get("alt"):
        lines.append(f"ALT: {c['alt']}")
    return "\n".join(lines)


def norm(s: str) -> str:
    s = s.replace("[[", "").replace("]]", "").lower()
    return re.sub(r"[^\w\s]", "", re.sub(r"\s+", " ", s)).strip()


def score(c: dict, out: str) -> tuple[bool, str]:
    if c.get("unchanged"):
        ok = norm(out) == norm(c["heard"])
        return ok, "" if ok else "changed a clean dictation"
    low = out.lower()
    for t in c.get("must_contain", []):
        if t.lower() not in low:
            return False, f"missing '{t}'"
    for t in c.get("must_not_contain", []):
        if t.lower() in low:
            return False, f"still has '{t}'"
    return True, ""


def call(model: str, c: dict, api_key: str, reasoning: str) -> dict:
    body = {
        "model": model,
        "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": user_message(c)}],
        "temperature": 0,
        "max_tokens": 300,
        "stream": True,
        "provider": {"sort": "latency"},
    }
    if reasoning != "default":
        body["reasoning"] = {"effort": reasoning}
    req = urllib.request.Request(
        "https://openrouter.ai/api/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json",
                 "X-Title": "VoicePlus correction bake-off"})
    t0 = time.perf_counter()
    ttft, text, usage, provider = None, [], {}, None
    with urllib.request.urlopen(req, timeout=60) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data: ") or line == "data: [DONE]":
                continue
            ev = json.loads(line[6:])
            provider = ev.get("provider", provider)
            usage = ev.get("usage") or usage
            for ch in ev.get("choices", []):
                piece = (ch.get("delta") or {}).get("content") or ""
                if piece and ttft is None:
                    ttft = time.perf_counter() - t0
                text.append(piece)
    total = time.perf_counter() - t0
    return {"out": "".join(text).strip(), "ttft_ms": round((ttft or total) * 1000), "total_ms": round(total * 1000),
            "provider": provider, "usage": usage}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", nargs="*", default=DEFAULT_MODELS)
    ap.add_argument("--cases", default=str(HERE / "cases.jsonl"))
    ap.add_argument("--repeat", type=int, default=1, help="runs per case (latency spread)")
    ap.add_argument("--reasoning", default="none", help="none | minimal | low | default")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    api_key = key()
    cases = [json.loads(l) for l in Path(a.cases).read_text().splitlines() if l.strip()]
    results, summary = [], []
    for m in a.models:
        passed, ttfts, totals, cost = 0, [], [], 0.0
        print(f"\n=== {m}")
        for c in cases:
            r = None
            for _ in range(a.repeat):
                try:
                    r = call(m, c, api_key, a.reasoning)
                except Exception as e:  # keep going: one bad endpoint should not end the run
                    r = {"out": f"<error {e}>", "ttft_ms": 0, "total_ms": 0, "provider": None, "usage": {}}
                    break
                ttfts.append(r["ttft_ms"]); totals.append(r["total_ms"])
            ok, why = score(c, r["out"])
            passed += ok
            cost += float((r.get("usage") or {}).get("cost") or 0)
            results.append({"model": m, "case": c["id"], "ok": ok, "why": why, **r})
            print(f"  {'PASS' if ok else 'FAIL'} {c['id']:<28} {r['ttft_ms']:>5} ms ttft {r['total_ms']:>5} ms  {r['out'][:90]!r} {why}")
        p = lambda xs, q: sorted(xs)[min(len(xs) - 1, int(q * len(xs)))] if xs else 0
        summary.append((m, passed, len(cases), p(ttfts, .5), p(totals, .5), p(totals, .9), cost))
    print("\nmodel | pass | ttft p50 | total p50 | total p90 | cost for run (USD)")
    for m, ok, n, t50, a50, a90, cost in sorted(summary, key=lambda s: (-s[1], s[4])):
        print(f"{m} | {ok}/{n} | {t50} ms | {a50} ms | {a90} ms | {cost:.5f}")
    if a.out:
        Path(a.out).write_text(json.dumps({"summary": summary, "results": results}, indent=2))


if __name__ == "__main__":
    main()
