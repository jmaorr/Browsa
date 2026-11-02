#!/usr/bin/env python3
"""Builds Packages/BrowserKit/Sources/Suggest/Resources/seed-sites.json.

Source: Chrome UX Report top lists (real Chrome page loads), cached monthly at
github.com/zakird/crux-top-lists. CrUX buckets sites by rank magnitude (top 1K, 5K, 10K...)
and shuffles inside each bucket, so we order sites by how popular they are *across ~50
countries*: a site in the top 1K of 45 countries outranks one in the top 1K of 3.

Each entry:  {"d": domain, "w": 0..1 popularity, "n": name?, "r": [regions]?, "a": [aliases]?}
  n  only when the curated name differs from the derived one (Swift derives the rest)
  r  ISO regions where the site is a local favourite, so an Australian typing "ama" gets
     amazon.com.au and a German gets amazon.de
  a  typed shortcuts: "yt" -> youtube.com, "gh" -> github.com

Filtering: StevenBlack porn/gambling/fake-news/malware hosts, the Block List Project piracy
list, and keyword patterns. Curated names and aliases live in tools/seed_curated.json.

    python3 tools/build_seed.py --month 202609 --global-top 6000
"""
import argparse, collections, csv, gzip, io, json, pathlib, re, urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "Packages/BrowserKit/Sources/Suggest/Resources/seed-sites.json"
CURATED = ROOT / "tools/seed_curated.json"
CRUX = "https://raw.githubusercontent.com/zakird/crux-top-lists/main/data"
COUNTRIES = ("au nz us gb ca ie de fr es it nl se no dk fi pl pt br mx ar in jp kr sg my id ph "
             "th vn za ng eg ae sa tr il ch at be cz gr ro hu ua cl co hk tw").split()
BLOCKLISTS = [
    "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/porn-only/hosts",
    "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/gambling-only/hosts",
    "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-only/hosts",
    "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts",
    "https://raw.githubusercontent.com/blocklistproject/Lists/master/alt-version/porn-nl.txt",
    "https://raw.githubusercontent.com/blocklistproject/Lists/master/alt-version/piracy-nl.txt",
]
PSL = "https://raw.githubusercontent.com/publicsuffix/list/main/public_suffix_list.dat"
BLOCK_PATTERNS = re.compile("|".join([
    r"porn", r"xxx", r"sex", r"xvideo", r"xnxx", r"xham", r"onlyfans", r"hentai", r"adult", r"nude",
    r"naked", r"erotic", r"escort", r"camgirl", r"chaturbate", r"stripchat", r"fap", r"milf", r"nsfw",
    r"rule34", r"booru", r"jav", r"hanime", r"lewd", r"fetish", r"boob", r"tits", r"pussy", r"dick",
    r"casino", r"\bbet", r"betting", r"poker", r"slot", r"gambl", r"lottery", r"togel", r"judi",
    r"1xbet", r"stake\.", r"pinup", r"bk8", r"\bpin-?up",
    r"torrent", r"pirate", r"123movie", r"fmovies", r"putlocker", r"gomovies", r"soap2day", r"yts\.",
    r"9anime", r"gogoanime", r"animepahe", r"zoro\.", r"manga(?:dex|kakalot|nato)", r"kissanime",
    r"akamai", r"cloudfront", r"googleapis", r"gstatic", r"doubleclick", r"fbcdn", r"googleusercontent",
    r"amazonaws", r"azureedge", r"edgekey", r"trafficmanager", r"\bcdn", r"^api\.", r"tracking",
    r"^(?:\d+\.){3}\d+$", r"localhost",
    # Downloaders, rippers and piracy mirrors.
    r"movierulz", r"filmyzilla", r"hdhub", r"y2mate", r"ytmp3", r"mp3", r"ssstik", r"snaptik", r"savefrom",
    r"fdown", r"fastdl", r"downloader", r"fitgirl", r"repack", r"steamrip", r"roms", r"liteapk", r"modapk",
    r"goojara", r"moviezda", r"tamildhool", r"drama", r"oceanofpdf", r"scans\.", r"manga", r"toon\d",
    r"freewebnovel", r"novel\d", r"lk21", r"anime", r"movies?\d", r"watch.*free", r"streameast", r"crack",
    r"^xn--", r"^xh[a-z]+\.", r"xnhau", r"xnxt", r"filmyfly", r"bollyflix", r"kooratv", r"satta", r"matka", r"bpexch", r"^search-start", r"^online-reservations", r"redirect", r"relay\.", r"quizwinz",
]))
# Throwaway TLDs that are almost all mirrors or spam in these lists.
BAD_TLDS = set("to cc sc gs solutions forex fitness university ventures bi xyz top icu cfd sbs click lol "
               "site online fun buzz pw ws tk ml ga cf gq rest monster bond".split())
DIGIT_PATTERN = re.compile(r"\d")
# Subdomains worth keeping as their own entry (docs.google.com, open.spotify.com...).
SERVICE_LABELS = set("""mail docs drive maps calendar news translate photos music play scholar meet chat
outlook app web open studio console cloud developer developers finance sports weather shop store
gemini keep classroom sites earth lens vids aistudio notebooklm teams onedrive admin learn""".split())
STRIP_PREFIXES = ("www.", "m.", "mobile.", "amp.", "touch.", "en.", "en-us.", "web.")

GLOBAL_W = {1000: 1.0, 5000: 0.82, 10000: 0.7, 50000: 0.55, 100000: 0.45, 500000: 0.3, 1000000: 0.2}
COUNTRY_W = {1000: 1.0, 5000: 0.7, 10000: 0.55, 50000: 0.35, 100000: 0.25, 500000: 0.1, 1000000: 0.05}


def fetch(url, cache: pathlib.Path) -> bytes:
    if cache.exists():
        return cache.read_bytes()
    cache.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url, timeout=120) as r:
        data = r.read()
    cache.write_bytes(data)
    return data


class Suffixes:
    def __init__(self, text: str):
        self.rules, self.wild, self.exc = set(), set(), set()
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("//"):
                continue
            if line.startswith("!"):
                self.exc.add(line[1:])
            elif line.startswith("*."):
                self.wild.add(line[2:])
            else:
                self.rules.add(line)

    def registrable(self, host: str) -> str:
        labels = host.split(".")
        for i in range(len(labels)):
            cand = ".".join(labels[i:])
            parent = ".".join(labels[i + 1:])
            if cand in self.exc:
                return cand
            if cand in self.rules or parent in self.wild:
                return ".".join(labels[i - 1:]) if i > 0 else host
        return ".".join(labels[-2:])


def read_crux(data: bytes):
    rows = csv.reader(io.TextIOWrapper(gzip.GzipFile(fileobj=io.BytesIO(data)), encoding="utf-8"))
    next(rows)
    for origin, rank in rows:
        host = origin.split("://", 1)[-1].split("/")[0].split(":")[0].lower()
        yield host, int(rank)


def read_blocklist(data: bytes) -> set:
    out = set()
    for line in data.decode("utf-8", "ignore").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        d = parts[1] if len(parts) >= 2 and parts[0] in ("0.0.0.0", "127.0.0.1") else parts[0]
        if "." in d:
            out.add(d.lower())
    return out


def canonical(host: str, psl: Suffixes) -> str:
    changed = True
    while changed:
        changed = False
        for p in STRIP_PREFIXES:
            if host.startswith(p) and host.count(".") >= 2:
                host = host[len(p):]
                changed = True
    reg = psl.registrable(host)
    # Keep one meaningful service label (docs.google.com), collapse everything else.
    if host != reg and (host.split(".")[0] not in SERVICE_LABELS or host.count(".") != reg.count(".") + 1):
        host = reg
    if host.startswith("wikipedia.") or host.endswith(".wikipedia.org"):
        host = "wikipedia.org"
    return host


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--month", default="202609")
    ap.add_argument("--global-top", type=int, default=6000)
    ap.add_argument("--regional-per-country", type=int, default=250)
    ap.add_argument("--cache", default=str(ROOT / ".seed-cache"))
    args = ap.parse_args()
    cache = pathlib.Path(args.cache)

    psl = Suffixes(fetch(PSL, cache / "psl.dat").decode())
    blocked = set()
    for i, url in enumerate(BLOCKLISTS):
        blocked |= read_blocklist(fetch(url, cache / f"block{i}.txt"))
    # A whole registrable domain is blocked only when the list names that domain itself, never
    # because one of its subdomains is an ad server (the hosts file lists ads.google.com etc.).
    blocked_reg = {b for b in blocked if psl.registrable(b) == b}

    curated = json.loads(CURATED.read_text()) if CURATED.exists() else {}
    allow = set(curated.get("allow", [])) | set(curated.get("names", {}))
    deny = set(curated.get("deny", []))

    def is_blocked(d: str) -> bool:
        if d in allow:
            return False
        if d in deny or d in blocked or psl.registrable(d) in blocked_reg or BLOCK_PATTERNS.search(d):
            return True
        if d.rsplit(".", 1)[-1] in BAD_TLDS:
            return True
        label = d.split(".")[0]
        # "ay267", "hai8g", "filmyzilla70": digit-mangled names are nearly always mirrors.
        if DIGIT_PATTERN.search(label) and (len(label) <= 6 or label[-1].isdigit()
                                            or len(DIGIT_PATTERN.findall(label)) >= 2):
            return True
        return False

    gbest = {}
    for host, rank in read_crux(fetch(f"{CRUX}/global/current.csv.gz", cache / "global.csv.gz")):
        d = canonical(host, psl)
        gbest[d] = min(gbest.get(d, 10**7), rank)

    cbest = collections.defaultdict(dict)  # domain -> {country: best rank}
    for c in COUNTRIES:
        data = fetch(f"{CRUX}/country/{c}/{args.month}.csv.gz", cache / f"{c}-{args.month}.csv.gz")
        for host, rank in read_crux(data):
            if rank > 50000:
                break
            d = canonical(host, psl)
            prev = cbest[d].get(c)
            if prev is None or rank < prev:
                cbest[d][c] = rank

    n = len(COUNTRIES)

    def popularity(d):
        g = GLOBAL_W.get(gbest.get(d), 0.0)
        breadth = sum(COUNTRY_W[r] for r in cbest.get(d, {}).values()) / n
        # A hair off for longer domains breaks the many ties at the top (google.com > google.com.hk).
        return 0.55 * g + 0.45 * breadth - 0.0004 * len(d)

    def regions(d):
        tld = d.rsplit(".", 1)[-1]
        out = [c for c, r in cbest.get(d, {}).items()
               if r <= 1000 and (gbest.get(d, 10**7) > 1000 or tld == c or len(cbest[d]) <= 12)]
        if len(out) > 8:
            return []  # popular nearly everywhere: no regional boost needed
        return sorted(out)

    candidates = set(gbest) | set(cbest)
    clean = [d for d in candidates if not is_blocked(d)]
    ranked = sorted(clean, key=popularity, reverse=True)
    chosen = ranked[: args.global_top]
    chosen_set = set(chosen)
    # Regional favourites that didn't make the global cut.
    for c in COUNTRIES:
        local = sorted((d for d in clean if cbest.get(d, {}).get(c, 10**7) <= 1000),
                       key=lambda d: (cbest[d][c], -popularity(d)))
        for d in local[: args.regional_per_country]:
            if d not in chosen_set:
                chosen.append(d)
                chosen_set.add(d)

    names, aliases, extra = curated.get("names", {}), curated.get("aliases", {}), curated.get("extra", [])
    for d in extra:  # must-haves CrUX misses (e.g. app-only services' web front doors)
        if d not in chosen_set:
            chosen.append(d)
            chosen_set.add(d)

    top = max(popularity(d) for d in chosen) or 1
    out = []
    for d in sorted(chosen, key=popularity, reverse=True):
        e = {"d": d, "w": round(max(popularity(d) / top, 0.01), 3)}
        if d in names:
            e["n"] = names[d]
        r = regions(d)
        if r:
            e["r"] = r
        if d in aliases:
            e["a"] = aliases[d]
        out.append(e)
    OUT.write_text("[\n" + ",\n".join(json.dumps(e, ensure_ascii=False, separators=(",", ":")) for e in out) + "\n]\n")
    print(f"{len(out)} sites -> {OUT.relative_to(ROOT)} ({OUT.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
