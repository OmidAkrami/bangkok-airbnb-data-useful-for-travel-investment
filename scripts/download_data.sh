#!/usr/bin/env bash
# Downloads the Bangkok files from Inside Airbnb into data/raw/<snapshot>/
# listings for all 24 monthly snapshots, plus calendar, reviews and the
# district boundaries for the latest one. About 450 MB in total.
#
# The archive dates aren't listed anywhere obvious, I found them by trying
# dates against the URL pattern. May 2026 doesn't exist.

set -euo pipefail
cd "$(dirname "$0")/.."

BASE="https://data.insideairbnb.com/thailand/central-thailand/bangkok"
LATEST="2026-09-22"

SNAPSHOTS="
2024-09-25 2024-10-24 2024-11-28 2024-12-25
2025-01-29 2025-02-20 2025-03-19 2025-04-25 2025-05-26 2025-06-24
2025-07-26 2025-08-28 2025-09-26 2025-10-29 2025-11-27 2025-12-28
2026-01-25 2026-02-26 2026-03-30 2026-04-27 2026-06-29 2026-07-23
2026-08-30 2026-09-22
"

for d in $SNAPSHOTS; do
    mkdir -p "data/raw/$d"
    if [ ! -f "data/raw/$d/listings.csv.gz" ]; then
        echo "listings $d"
        curl -sSf -o "data/raw/$d/listings.csv.gz" "$BASE/$d/data/listings.csv.gz"
    fi
done

for f in data/calendar.csv.gz data/reviews.csv.gz visualisations/neighbourhoods.csv visualisations/neighbourhoods.geojson; do
    out="data/raw/$LATEST/$(basename "$f")"
    [ -f "$out" ] || { echo "$f"; curl -sSf -o "$out" "$BASE/$LATEST/$f"; }
done

echo "done"
