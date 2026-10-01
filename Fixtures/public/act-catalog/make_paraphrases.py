#!/usr/bin/env python3
"""V5 CU6 — build `paraphrases.json` from the shipped action catalogue.

Every catalogue phrasing gets 3 paraphrases from fixed, rule-based rewrites (verb synonyms, added
determiners, polite/filler wrappers, spoken-number forms). The rules are generic and are never
tuned to make a case pass: a failing paraphrase is fixed in `catalog.json` (CU6: "failures →
catalogue fixes, not model changes"), and this script is re-run.

    python3 Fixtures/public/act-catalog/make_paraphrases.py
"""
import json, os, re, zlib

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(ROOT, "..", "..", ".."))
CATALOG = os.path.join(REPO, "Actions", "Deterministic", "catalog.json")
OUT = os.path.join(ROOT, "paraphrases.json")

# App the case runs in, per entry category (mac entries run in Notes so browser entries don't shadow them).
APP_FOR = {"mac": "com.apple.Notes", "browser": "com.apple.Safari", "editor": "com.microsoft.VSCode",
           "chat": "com.tinyspeck.slackmacgap", "mail": "com.apple.mail", "files": "com.apple.finder"}

def argument(kind):
    return {"focusApp": "Preview", "focusWindow": "Second", "click": "Toolbar", "focusTab": "Overview",
            "openURL": "github dot com slash pulls", "openFile": "~/Documents"}.get(kind, "hello world")

# Whole-phrase-start verb synonyms (first match wins). Generic English, not per-entry.
SYNONYMS = [
    ("go to ", "navigate to "), ("switch to ", "change to "), ("jump to ", "skip to "),
    ("open ", "bring up "), ("show ", "display "), ("close ", "shut "), ("click ", "press "),
    ("press ", "hit "), ("hit ", "press "), ("tap ", "click "), ("scroll ", "move "), ("search ", "look for "),
    ("find ", "look for "), ("delete ", "remove "), ("toggle ", "flip "), ("hide ", "put away "),
    ("new ", "a new "), ("next ", "the next "), ("previous ", "the previous "), ("quit", "exit"),
    ("minimize", "shrink"), ("maximize", "make bigger"), ("reload", "refresh"), ("refresh", "reload"),
    ("run", "execute"), ("select ", "highlight "), ("add ", "create "), ("create ", "make "),
    ("mark ", "set "), ("set ", "change "), ("reply", "respond"), ("save", "save it"),
    ("type ", "enter "), ("write ", "type "), ("fill ", "fill in "), ("copy", "copy it"),
    ("paste", "paste it"), ("undo", "undo it"), ("redo", "redo it"), ("send", "send it"),
]
NUMBERS = {"1": "one", "2": "two", "3": "three"}
DETERMINERS = ("the", "this", "a", "my", "that", "it")

VERBS = {"open", "close", "show", "go", "switch", "click", "press", "hit", "tap", "scroll", "search", "find",
         "delete", "toggle", "hide", "minimize", "maximize", "restore", "zoom", "reload", "reopen", "focus",
         "select", "add", "create", "make", "mark", "set", "move", "duplicate", "rename", "format", "split",
         "save", "edit", "fold", "unfold", "collapse", "expand", "insert", "take", "lock", "copy", "paste",
         "join", "leave", "pin", "forward", "archive", "flag", "accept", "reject", "decline",
         "approve", "run", "start", "comment", "indent", "jump", "enter", "empty", "get", "send", "keep"}

def with_determiner(head):
    words = head.split()
    if len(words) < 2 or words[0] not in VERBS or any(w in DETERMINERS for w in words):
        return None
    return " ".join(words[:-1] + ["the", words[-1]])

def wrappers(text, seed, templated):
    # A template's argument runs to the end of the utterance, so only prefixes wrap it.
    forms = ([f"ok {text}", f"um {text}", f"now {text}", f"okay {text}"] if templated else
             [f"{text} please", f"ok {text}", f"{text} for me", f"um {text}", f"{text} now"])
    k = seed % len(forms)
    return forms[k:] + forms[:k]

def paraphrases(head, arg, exact, everywhere):
    out = []
    def push(h):
        t = (h + (" " + arg if arg else "")).strip()
        t = re.sub(r"\s+", " ", t)
        # Not a paraphrase if it is already a phrasing (of this entry, or of another one).
        if t not in out and t not in exact and h.strip() not in everywhere:
            out.append(t)
    for a, b in SYNONYMS:
        # "go to " rewrites a prefix; a bare word ("save") rewrites only the whole head.
        if a.endswith(" ") and head.startswith(a):
            push(b + head[len(a):]); break
        if head == a.strip():
            push(b.strip()); break
    d = with_determiner(head)
    if d: push(d)
    for n, w in NUMBERS.items():
        if re.search(rf"\b{n}\b", head):
            push(re.sub(rf"\b{n}\b", w, head))
    for w in wrappers(head, zlib.crc32(head.encode()), bool(arg)):
        if len(out) >= 3: break
        push(w)
    return out[:3]

def main():
    catalog = json.load(open(CATALOG))
    cases = []
    everywhere = {(p[:-5] if p.endswith("{arg}") else p).strip() for e in catalog for p in e["phrasings"]}
    for e in catalog:
        cat = e["apps"][0] if e["apps"] else "mac"
        arg = argument(e["kind"])
        exact_texts = set()
        for p in e["phrasings"]:
            head = p[:-5].strip() if p.endswith("{arg}") else p
            exact_texts.add((head + (" " + arg if p.endswith("{arg}") else "")).strip())
        for p in e["phrasings"]:
            templ = p.endswith("{arg}")
            head = p[:-5].strip() if templ else p
            a = arg if templ else ""
            text = (head + (" " + a if a else "")).strip()
            cases.append({"entry": e["id"], "app": APP_FOR[cat], "phrasing": p, "text": text,
                          "paraphrases": paraphrases(head, a, exact_texts, everywhere)})
    doc = {"name": "act-catalog-200",
           "note": "V5 CU6: every catalogue phrasing (exact, {arg} filled) x 3 rule-based paraphrases; "
                   "generated by make_paraphrases.py from Actions/Deterministic/catalog.json.",
           "cases": cases}
    with open(OUT, "w") as f:
        json.dump(doc, f, indent=1, ensure_ascii=False)
        f.write("\n")
    n = sum(len(c["paraphrases"]) for c in cases)
    print(f"{len(catalog)} entries, {len(cases)} phrasings, {n} paraphrases -> {os.path.relpath(OUT, REPO)}")

if __name__ == "__main__":
    main()
