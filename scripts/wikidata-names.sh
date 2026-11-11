#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Rewrites eval/classes/names.wikidata.tsv: the given names of Wikidata (CC0)
# with 8 or more sitelinks, labels in ru, en and uk, the best linked first.
# Run by hand when the snapshot should be renewed, and commit the result:
# the answer of the query service changes with the database, so it is a
# snapshot in the repository and not a source of scripts/fetch-data.sh.
# The service cuts a long query off after a minute; 8 sitelinks is what it
# answers in time (5 gets a truncated answer).
#
# Usage: scripts/wikidata-names.sh
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=eval/classes/names.wikidata.tsv
MIN_LINKS=8
QUERY='SELECT ?ru ?en ?uk ?links WHERE {
  VALUES ?type { wd:Q12308941 wd:Q11879590 wd:Q3409032 }
  ?item wdt:P31 ?type; wikibase:sitelinks ?links.
  FILTER(?links >= '"$MIN_LINKS"')
  OPTIONAL { ?item rdfs:label ?ru. FILTER(LANG(?ru) = "ru") }
  OPTIONAL { ?item rdfs:label ?en. FILTER(LANG(?en) = "en") }
  OPTIONAL { ?item rdfs:label ?uk. FILTER(LANG(?uk) = "uk") }
}'
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl --fail --location --silent --show-error --max-time 150 --retry 3 \
    -H 'Accept: application/sparql-results+json' \
    -H 'User-Agent: perekey-eval-bench (snapshot of given names; scripts/wikidata-names.sh)' \
    --get --data-urlencode "query=$QUERY" https://query.wikidata.org/sparql --output "$tmp"
python3 -I - "$tmp" "$OUT" "$MIN_LINKS" "$QUERY" <<'PY'
import json, sys, datetime
src, out, min_links, query = sys.argv[1:5]
try:
    rows = json.load(open(src))["results"]["bindings"]
except Exception as error:
    sys.exit(f"wikidata-names: the answer is not a result ({error}); the service cut the query off, try again")
names = []
for row in rows:
    cells = [row.get(k, {}).get("value", "") for k in ("ru", "en", "uk")]
    links = int(row["links"]["value"])
    if any(cells) and all("\t" not in c and "\n" not in c for c in cells):
        names.append((links, *cells))
names.sort(key=lambda r: (-r[0], r[1], r[2], r[3]))
with open(out, "w") as f:
    f.write(f"# Given names of Wikidata (male, female, unisex), {min_links} or more sitelinks. License: CC0.\n")
    f.write(f"# Snapshot of {datetime.date.today().isoformat()} by scripts/wikidata-names.sh; the query:\n")
    for line in query.splitlines():
        f.write(f"#   {line}\n")
    f.write("ru\ten\tuk\tlinks\n")
    for links, ru, en, uk in names:
        f.write(f"{ru}\t{en}\t{uk}\t{links}\n")
print(f"wikidata-names: {len(names)} names to {out}")
PY
