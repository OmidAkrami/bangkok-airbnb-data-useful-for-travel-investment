"""Bundle the dashboard CSVs and a simplified district map into docs/data.js.

docs/index.html reads it as a plain script, so the page works on GitHub Pages
and straight from disk, with no server or build step.

usage: python scripts/make_dashboard_data.py
"""
import json
import math
import pathlib

import pandas as pd
from shapely.geometry import MultiPolygon, mapping, shape
from shapely.geometry.polygon import orient

ROOT = pathlib.Path(__file__).resolve().parent.parent
RES = ROOT / "results"
DASH = ROOT / "dashboard"
OUT = ROOT / "docs" / "data.js"

NAMES = {
    "Parthum Wan": "Pathum Wan",
    "Chatu Chak": "Chatuchak",
    "Thon buri": "Thon Buri",
    "Suanluang": "Suan Luang",
    "Yan na wa": "Yan Nawa",
    "Bang Kho laen": "Bang Kho Laem",
    "Bang Khun thain": "Bang Khun Thian",
    "Thung khru": "Thung Khru",
    "Pra Wet": "Prawet",
}


def records(df):
    """DataFrame to a list of dicts with NaN turned into null."""
    out = []
    for row in df.to_dict("records"):
        out.append({k: (None if isinstance(v, float) and math.isnan(v) else v) for k, v in row.items()})
    return out


def geometry():
    """District shapes, simplified to about 10 m so data.js stays small."""
    geo = json.loads((DASH / "bangkok_districts.geojson").read_text())
    features = []
    for f in geo["features"]:
        g = shape(f["geometry"]).simplify(0.0001, preserve_topology=True)
        # d3 wants exterior rings clockwise, otherwise it fills the rest of the globe
        g = MultiPolygon([orient(p, sign=-1.0) for p in getattr(g, "geoms", [g])])
        geom = json.loads(json.dumps(mapping(g)))  # tuples to lists
        geom["coordinates"] = [[[[round(x, 5), round(y, 5)] for x, y in ring] for ring in poly]
                               for poly in geom["coordinates"]]
        features.append({"type": "Feature", "properties": {"district": f["properties"]["neighbourhood"]},
                         "geometry": geom})
    return {"type": "FeatureCollection", "features": features}


def main():
    districts = pd.read_csv(DASH / "districts.csv")
    price = pd.read_csv(RES / "price_by_district.csv")[["district", "median_thb", "price_rank", "listings"]]
    price = price.rename(columns={"median_thb": "price_all_nightly_thb", "listings": "priced_nightly_listings"})
    occ = pd.read_csv(RES / "occ_by_district.csv")[["district", "median_occ_pct", "active_listings"]]
    occ = occ.rename(columns={"median_occ_pct": "occ_all_active_pct", "active_listings": "occ_active"})
    d = districts.merge(price, on="district", how="left").merge(occ, on="district", how="left")
    # only show a district price or occupancy when it rests on 30+ listings
    d.loc[d.price_rank.isna(), "price_all_nightly_thb"] = None
    d.loc[d.occ_active.fillna(0) < 30, "occ_all_active_pct"] = None
    d["name"] = d.district.map(lambda x: NAMES.get(x, x))
    d = d.drop(columns=["price_rank", "occ_active", "lat", "lon"])

    # city medians for the price vs occupancy scatter, same base as
    # price_district_quadrants: active entire homes with a 1 to 6 night minimum
    ls = pd.read_csv(DASH / "listings.csv")
    base = ls[(ls.room_type == "Entire home/apt") & ls.is_active & (ls.min_nights <= 6) & ls.price_thb.notna()]
    scatter_city = {"price_thb": round(float(base.price_thb.median())),
                    "occ_pct": round(float(base.est_occ_pct.median()), 1)}

    data = {
        "scatterCity": scatter_city,
        "kpis": records(pd.read_csv(DASH / "kpis.csv"))[0],
        "districts": records(d),
        "monthly": records(pd.read_csv(DASH / "monthly.csv")),
        "hostTiers": records(pd.read_csv(DASH / "host_tiers.csv")),
        "shortVsMonthly": records(pd.read_csv(RES / "price_short_vs_monthly.csv")),
        "seasonality": records(pd.read_csv(RES / "trend_seasonality.csv")),
        "geo": geometry(),
        "names": NAMES,
    }
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text("window.DATA = " + json.dumps(data, separators=(",", ":")) + ";\n")
    print(OUT.relative_to(ROOT), round(OUT.stat().st_size / 1e3), "KB")


if __name__ == "__main__":
    main()
