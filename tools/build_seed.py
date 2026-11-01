#!/usr/bin/env python3
"""Build Packages/BrowserKit/Sources/Suggest/Resources/seed-sites.json from the Tranco list.

The checked-in seed list is a hand-curated starter (~130 sites). Run this on your Mac to
expand it to the top N domains:

    python3 tools/build_seed.py --top 10000

Curated entries already in the JSON keep their display names and stay at the top; Tranco
adds the rest with names derived from the domain. Domains matching BLOCK_PATTERNS
(adult, malware or CDN infrastructure) are dropped. Add your own patterns as needed.
"""
import argparse, csv, io, json, pathlib, re, urllib.request, zipfile

SEED = pathlib.Path(__file__).resolve().parents[1] / "Packages/BrowserKit/Sources/Suggest/Resources/seed-sites.json"
TRANCO = "https://tranco-list.eu/top-1m.csv.zip"
BLOCK_PATTERNS = [
    r"porn", r"xxx", r"sex", r"xvideos", r"xnxx", r"onlyfans", r"hentai", r"adult",
    # infrastructure domains nobody types
    r"akamai", r"cloudfront", r"googleapis", r"gstatic", r"doubleclick", r"fbcdn",
    r"amazonaws", r"azureedge", r"edgekey", r"trafficmanager", r"cdn", r"^api\.", r"tracking",
]

def pretty_name(domain: str) -> str:
    label = domain.split(".")[0]
    return label.replace("-", " ").title()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--top", type=int, default=10000)
    args = ap.parse_args()

    curated = json.loads(SEED.read_text()) if SEED.exists() else []
    seen = {s["d"] for s in curated}
    block = re.compile("|".join(BLOCK_PATTERNS))

    with urllib.request.urlopen(TRANCO) as r:
        z = zipfile.ZipFile(io.BytesIO(r.read()))
    rows = csv.reader(io.TextIOWrapper(z.open(z.namelist()[0])))

    extra = []
    for rank, domain in rows:
        rank = int(rank)
        if rank > args.top:
            break
        if domain in seen or block.search(domain):
            continue
        seen.add(domain)
        extra.append({"d": domain, "n": pretty_name(domain), "w": round(1 - rank / (args.top * 1.25), 3)})

    # Curated entries keep their weights; scale Tranco weights below the curated floor.
    floor = min((s["w"] for s in curated), default=1.0)
    for e in extra:
        e["w"] = round(e["w"] * floor, 3)

    SEED.write_text(json.dumps(curated + extra, indent=0, ensure_ascii=False))
    print(f"{len(curated)} curated + {len(extra)} from Tranco -> {SEED}")

if __name__ == "__main__":
    main()
