"""Writes the three raw tables to parquet so the Kaggle notebook doesn't have
to parse 450 MB of gzipped CSV. Run build.py first.

Output goes to data/kaggle/, which is what I uploaded as the Kaggle dataset.
Host names are left out of the Kaggle copy; the analysis only ever shows
them for accounts with 20+ listings, and doesn't need them at all.
"""
import pathlib
import shutil

import duckdb

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "data" / "kaggle"
OUT.mkdir(parents=True, exist_ok=True)

con = duckdb.connect(str(ROOT / "bangkok.duckdb"), read_only=True)
for t, query in (("listings", "select * exclude (host_name) from raw_listings"),
                 ("calendar", "select * from raw_calendar"),
                 ("reviews", "select * from raw_reviews")):
    path = OUT / f"{t}.parquet"
    con.execute(f"copy ({query}) to '{path}' (format parquet, compression zstd)")
    print(path.name, round(path.stat().st_size / 1e6, 1), "MB")

shutil.copy(ROOT / "dashboard" / "bangkok_districts.geojson", OUT / "bangkok_districts.geojson")
