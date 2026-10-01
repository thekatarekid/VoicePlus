#!/usr/bin/env python3
"""V5 P3 — generate Fixtures/dictionaries/casing.txt offline.

Sources (all fetched at generation time, never at runtime):
  * Wikidata (CC0) — English labels of software, programming languages, web services, apps,
    operating systems, companies and brands, ordered by sitelink count.
  * Homebrew casks (BSD-2-Clause metadata) — display names ("iTerm2", "OBS", "VLC").
npm / PyPI / Homebrew-formula names are lowercase by convention, so they carry no casing
information; they are deliberately not used for this list (see README.md).

Filter (the CasingStage only *re-cases* tokens, so the list must never contain a common word):
  * one token, 2..32 chars, letters/digits plus internal . - + only, at least two letters;
  * not all lowercase (a lowercase canonical form fixes nothing);
  * (hand-curated casing-supplement.txt entries skip the next rule)
  * its lowercase form is NOT an English word (/usr/share/dict/words lowercase entries plus
    a small modern supplement) — so "Ruby", "Swift", "Apple", "Go" never enter the list;
  * regular inflections of English words are words too ("batteries", "focused");
  * a top-10k frequent word survives only as a camel-case form (JavaScript), never Titlecase or
    all-caps ("Zen", "MAX") — frequency list fetched at generation time only, never shipped;
  * one canonical per lowercase key: the most-linked Wikidata item wins.

Usage:  python3 Fixtures/dictionaries/generate_casing.py [--limit 20000] [--out casing.txt]
        python3 Fixtures/dictionaries/generate_casing.py --swift-only   # re-emit the compiled copy
Writes casing.txt and Pipeline/Dictionaries/CasingLexicon+Bundled.swift (the copy the app ships).
"""
import argparse, csv, io, json, os, re, sys, urllib.parse, urllib.request

UA = "VoicePlusDictGen/0.1 (offline casing list; contact: repository owner)"
CLASSES = {
    "Q7397": "software", "Q9143": "programming language", "Q193424": "web service",
    "Q1639024": "mobile app", "Q166142": "application", "Q9135": "operating system",
    "Q35127": "website", "Q4830453": "business", "Q891723": "public company",
    "Q431289": "brand", "Q506883": "FOSS", "Q341": "free software", "Q1172284": "dataset",
    "Q15401930": "product", "Q7889": "video game", "Q783794": "company",
}
TOKEN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.+\-]{1,31}$")
MODERN = {"email", "online", "website", "app", "apps", "blog", "login", "logout", "username", "wifi",
          "smartphone", "laptop", "internet", "download", "upload", "video", "podcast", "emoji",
          "selfie", "hashtag", "browser", "inbox", "spam", "cloud", "server", "admin", "dev", "repo"}


def english_words():
    words = set(MODERN)
    for path in ("/usr/share/dict/words", "/usr/share/dict/web2a"):
        if os.path.exists(path):
            with open(path, encoding="utf-8", errors="ignore") as f:
                for line in f:
                    w = line.strip()
                    if w and w == w.lower():
                        words.add(w)
    return words


FREQ_URL = "https://raw.githubusercontent.com/first20hours/google-10000-english/master/google-10000-english-no-swears.txt"


def frequent_words():
    """Top ~10k English words — a generation-time filter only, never shipped. Optional."""
    req = urllib.request.Request(FREQ_URL, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return {w.strip() for w in r.read().decode("utf-8").splitlines() if w.strip()}
    except Exception as e:
        print(f"frequency list: {e}", file=sys.stderr)
        return set()


def is_english(key, english):
    """True for a word or a regular inflection of one ("batteries", "focused", "shortcuts")."""
    if key in english:
        return True
    stems = []
    if key.endswith("ies"): stems.append(key[:-3] + "y")
    if key.endswith("es"): stems.append(key[:-2])
    if key.endswith("s"): stems.append(key[:-1])
    if key.endswith("ed"): stems += [key[:-2], key[:-1]]
    if key.endswith("ing"): stems += [key[:-3], key[:-3] + "e"]
    if key.endswith("er"): stems += [key[:-2], key[:-1]]
    return any(len(s) >= 3 and s in english for s in stems)


def sparql(query):
    url = "https://query.wikidata.org/sparql?" + urllib.parse.urlencode({"query": query})
    req = urllib.request.Request(url, headers={"Accept": "text/csv", "User-Agent": UA})
    with urllib.request.urlopen(req, timeout=120) as r:
        return list(csv.DictReader(io.StringIO(r.read().decode("utf-8"))))


def wikidata(limit_per_class):
    out = []
    for qid in CLASSES:
        q = f"""SELECT ?label ?links WHERE {{
  ?item wdt:P31 wd:{qid} ; wikibase:sitelinks ?links ; rdfs:label ?label .
  FILTER(LANG(?label) = "en") FILTER(?links >= 3)
}} ORDER BY DESC(?links) LIMIT {limit_per_class}"""
        rows = None
        for attempt in range(3):  # WDQS times out under load; one class failing must not lose the rest
            try:
                rows = sparql(q)
                break
            except Exception as e:
                print(f"wikidata {qid} attempt {attempt + 1}: {e}", file=sys.stderr)
        if rows is None:
            continue
        out += [(r["label"], int(r["links"])) for r in rows]
        print(f"wikidata {qid} {CLASSES[qid]}: {len(rows)}", file=sys.stderr)
    return out


def brew_casks():
    req = urllib.request.Request("https://formulae.brew.sh/api/cask.json", headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            casks = json.load(r)
    except Exception as e:
        print(f"homebrew casks: {e}", file=sys.stderr)
        return []
    return [(n, 2) for c in casks for n in c.get("name", [])]


SWIFT_OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Pipeline", "Dictionaries",
                         "CasingLexicon+Bundled.swift")


def emit_swift(casing_path, swift_path=SWIFT_OUT):
    """Compile casing.txt into the binary (Fixtures/ is not copied into the app bundle)."""
    with open(casing_path, encoding="utf-8") as f:
        words = [l.strip() for l in f if l.strip() and not l.startswith("#")]
    assert all('"""' not in w and "\\" not in w for w in words)
    with open(swift_path, "w", encoding="utf-8") as f:
        f.write("// GENERATED by Fixtures/dictionaries/generate_casing.py from casing.txt — do not edit.\n")
        f.write("// Data: Wikidata (CC0) + Homebrew cask names. See PublicDictionaryCatalog.casing.\n\n")
        f.write("extension CasingLexicon {\n    static let bundledCasingList = #\"\"\"\n")
        f.write("\n".join(words))
        f.write("\n\"\"\"#\n}\n")
    print(f"wrote {len(words)} entries to {os.path.normpath(swift_path)}", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=20000)
    ap.add_argument("--per-class", type=int, default=12000)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "casing.txt"))
    ap.add_argument("--swift-only", action="store_true", help="re-emit the Swift copy from --out, no network")
    args = ap.parse_args()
    if args.swift_only:
        emit_swift(args.out)
        return
    english = english_words()
    frequent = frequent_words()
    best = {}
    supplement_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "casing-supplement.txt")
    supplement = []
    if os.path.exists(supplement_path):
        with open(supplement_path, encoding="utf-8") as f:
            supplement = [(l.strip(), 10**6) for l in f if l.strip() and not l.startswith("#")]
    for label, links in supplement + wikidata(args.per_class) + brew_casks():
        label = label.strip()
        if not TOKEN.match(label) or sum(ch.isalpha() for ch in label) < 2:
            continue
        if label == label.lower() or label[-1] in ".-+":
            continue
        key = label.lower()
        curated = links >= 10**6
        if not curated:
            if is_english(key, english):
                continue
            # A frequent word only survives when its canonical form has an inner capital
            # (JavaScript, PayPal): "Batteries", "MAX", "Zen" would re-case ordinary speech.
            camel = any(ch.isupper() for ch in label[1:]) and any(ch.islower() for ch in label)
            if key in frequent and not camel:
                continue
        if key not in best or links > best[key][1]:
            best[key] = (label, links)
    ranked = sorted(best.values(), key=lambda t: (-t[1], t[0].lower()))[: args.limit]
    with open(args.out, "w", encoding="utf-8") as f:
        f.write("# VoicePlus casing list — generated by generate_casing.py. Data: Wikidata (CC0), Homebrew casks.\n")
        f.write("# One canonical form per line. Lines starting with # are comments.\n")
        for label, _ in sorted(ranked, key=lambda t: t[0].lower()):
            f.write(label + "\n")
    print(f"wrote {len(ranked)} entries to {args.out}", file=sys.stderr)
    emit_swift(args.out)


if __name__ == "__main__":
    main()
