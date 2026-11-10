"""Run every file in sql/ in order, then export the result views.

views starting with dash_ go to dashboard/, everything else that starts with
one of the prefixes below goes to results/.

usage: python scripts/build.py            (full run, loads raw files)
       python scripts/build.py --skip-load (reuse tables already in bangkok.duckdb)
"""
import os
import pathlib
import sys
import time

import duckdb

ROOT = pathlib.Path(__file__).resolve().parent.parent
PREFIXES = ("dq_", "occ_", "price_", "host_", "trend_", "stay_")

# the SQL reads data/raw/... relative to the repo root
os.chdir(ROOT)
con = duckdb.connect(str(ROOT / "bangkok.duckdb"))

skip_load = "--skip-load" in sys.argv
for f in sorted((ROOT / "sql").glob("*.sql")):
    if skip_load and f.name.startswith("00_"):
        continue
    t = time.time()
    con.execute(f.read_text())
    print(f"{f.name:<28} {time.time() - t:5.1f}s")

views = [r[0] for r in con.execute(
    "select table_name from information_schema.tables "
    "where table_type = 'VIEW' order by table_name"
).fetchall()]

for v in views:
    if v.startswith("dash_"):
        out = ROOT / "dashboard" / f"{v.removeprefix('dash_')}.csv"
    elif v.startswith(PREFIXES):
        out = ROOT / "results" / f"{v}.csv"
    else:
        continue
    con.sql(f"select * from {v}").write_csv(str(out))

print(f"exported {sum(v.startswith(PREFIXES + ('dash_',)) for v in views)} views")
