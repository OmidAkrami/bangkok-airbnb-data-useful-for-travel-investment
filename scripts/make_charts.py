"""Draw the README charts from the CSVs in results/ and dashboard/.

No database needed, so it runs straight after a fresh clone.

usage: python scripts/make_charts.py      (writes charts/*.png)
"""
import json
import pathlib

import matplotlib

matplotlib.use("Agg")
import matplotlib.dates
import matplotlib.patheffects
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from matplotlib.collections import PatchCollection
from matplotlib.patches import Patch, Polygon
from shapely.geometry import shape

ROOT = pathlib.Path(__file__).resolve().parent.parent
RES = ROOT / "results"
DASH = ROOT / "dashboard"
OUT = ROOT / "charts"
OUT.mkdir(exist_ok=True)

# colours
INK = "#0b0b0b"
INK_2 = "#52514e"
MUTED = "#898781"
GRID = "#e1e0d9"
AXIS = "#c3c2b7"
SURFACE = "#fcfcfb"
BLUE = "#2a78d6"
BLUE_LIGHT = "#86b6ef"
ORANGE = "#eb6834"
GREY = "#c3c2b7"
NO_DATA = "#ecebe6"
RAMP = ["#cde2fb", "#9ec5f4", "#5598e7", "#256abf", "#104281"]

SOURCE = "Source: Inside Airbnb, Bangkok. Analysis in SQL (DuckDB)."

# Inside Airbnb spells some districts differently from the usual romanisation.
# Display only; the data keeps the original names so joins still work.
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


def name(d):
    return NAMES.get(d, d)


plt.rcParams.update({
    "font.family": ["Helvetica Neue", "Helvetica", "Arial", "DejaVu Sans"],
    "font.size": 10,
    "text.color": INK,
    "axes.edgecolor": AXIS,
    "axes.labelcolor": INK_2,
    "axes.facecolor": SURFACE,
    "figure.facecolor": SURFACE,
    "axes.spines.top": False,
    "axes.spines.right": False,
    "axes.grid": False,
    "grid.color": GRID,
    "grid.linewidth": 0.8,
    "xtick.color": INK_2,
    "ytick.color": INK_2,
    "xtick.labelsize": 9,
    "ytick.labelsize": 9,
    "xtick.major.size": 0,
    "ytick.major.size": 0,
    "legend.frameon": False,
    "legend.fontsize": 9,
    "savefig.dpi": 160,
})


def figure(w, h, title, subtitle, note=None, ncols=1, **kw):
    """Figure with a left-aligned title block and a source line.

    The plot area is fitted between the two with tight_layout, so long tick
    labels push the plot instead of getting clipped.
    """
    fig, ax = plt.subplots(1, ncols, figsize=(w, h), **kw)
    sub_lines = subtitle.count("\n") + 1
    fig.text(0.03, 1 - 0.30 / h, title, fontsize=14.5, fontweight="bold", va="top")
    fig.text(0.03, 1 - 0.62 / h, subtitle, fontsize=10, color=INK_2, va="top", linespacing=1.45)
    foot = SOURCE if note is None else f"{note}\n{SOURCE}"
    fig.text(0.03, 0.18 / h, foot, fontsize=8, color=MUTED, va="bottom", linespacing=1.6)
    top = 1 - (0.62 + 0.205 * sub_lines + 0.22) / h
    bottom = (0.18 + 0.17 * (foot.count("\n") + 1) + 0.12) / h
    fig.set_layout_engine("tight", rect=(0.015, bottom, 0.985, top))
    return fig, ax


def save(fig, filename):
    fig.savefig(OUT / filename, facecolor=SURFACE)
    plt.close(fig)
    print("charts/" + filename)


def pct(x, _=None):
    return f"{x:.0f}%"


def city_median_price():
    o = pd.read_csv(RES / "price_city_overview.csv")
    return o[(o.room_type == "Entire home/apt") & (o.stay_type == "nightly")].median_thb.iloc[0]


# 1. district map: nightly price ------------------------------------------------
def district_map():
    geo = json.loads((DASH / "bangkok_districts.geojson").read_text())
    price = pd.read_csv(RES / "price_by_district.csv")
    ranked = price[price.price_rank.notna()].set_index("district")["median_thb"]
    top, second = ranked.nlargest(2).index
    second_2br = price.set_index("district").pct_2br_plus[second]
    second_n = price.set_index("district").listings[second]

    bins = [0, 1500, 2000, 2500, 3000, 1e9]
    labels = ["under 1,500", "1,500 to 2,000", "2,000 to 2,500", "2,500 to 3,000", "3,000 and over"]

    fig, (city_ax, zoom_ax) = figure(
        10, 6.8,
        f"{name(top)} is Bangkok's most expensive district at THB {ranked[top]:,.0f} a night",
        "Median asking price per night by district, active entire homes with a 1 to 6 night minimum, Sep 2026.\n"
        f"City median THB {city_median_price():,.0f}. Left: the whole city. Right: the centre, where most listings are.",
        note=f"{name(second)} ranks second on only {second_n} listings, {second_2br:.0f}% of them with 2+ bedrooms.",
        ncols=2, gridspec_kw={"width_ratios": [1, 1.35]},
    )

    patches, colours, centres = [], [], {}
    for f in geo["features"]:
        d = f["properties"]["neighbourhood"]
        v = ranked.get(d)
        c = NO_DATA if v is None else RAMP[np.digitize(v, bins[1:-1])]
        for poly in f["geometry"]["coordinates"]:
            patches.append(np.array(poly[0]))
            colours.append(c)
        # label at the centre of the district's largest piece
        biggest = max(shape(f["geometry"]).geoms, key=lambda g: g.area)
        centres[d] = np.array(biggest.centroid.coords[0])

    zoom = (100.478, 100.648, 13.672, 13.808)
    for ax, lw in ((city_ax, 0.6), (zoom_ax, 1.2)):
        ax.add_collection(PatchCollection([Polygon(r, closed=True) for r in patches],
                                          facecolor=colours, edgecolor=SURFACE, linewidth=lw))
        ax.autoscale_view()
        ax.set_aspect(1 / np.cos(np.radians(13.75)))
        ax.axis("off")
    zoom_ax.set_xlim(zoom[0], zoom[1])
    zoom_ax.set_ylim(zoom[2], zoom[3])
    city_ax.add_patch(matplotlib.patches.Rectangle((zoom[0], zoom[2]), zoom[1] - zoom[0], zoom[3] - zoom[2],
                                                   fill=False, edgecolor=INK_2, lw=1))

    halo = [matplotlib.patheffects.withStroke(linewidth=2.6, foreground=SURFACE)]
    # small districts get nudged so labels don't sit on top of each other
    nudge = {"Samphanthawong": (-0.010, -0.004), "Pom Prap Sattru Phai": (0.002, 0.012),
             "Parthum Wan": (0.002, 0.001), "Bang Rak": (-0.004, -0.002), "Phra Nakhon": (-0.004, 0.004),
             "Khlong San": (-0.006, 0.0), "Phaya Thai": (0.0, 0.004), "Sathon": (0.0, -0.004)}
    for d, (x, y) in centres.items():
        v = ranked.get(d)
        dx, dy = nudge.get(d, (0, 0))
        x, y = x + dx, y + dy
        if v is None or not (zoom[0] + 0.006 < x < zoom[1] - 0.006 and zoom[2] + 0.004 < y < zoom[3] - 0.004):
            continue
        label = "Pom Prap" if d == "Pom Prap Sattru Phai" else name(d)
        zoom_ax.text(x, y, f"{label}\n{v:,.0f}", fontsize=7.8, ha="center", va="center", color=INK,
                     linespacing=1.15, path_effects=halo, fontweight="bold" if d == top else "normal")

    handles = [Patch(facecolor=c, label=l) for c, l in zip(RAMP, labels)]
    handles.append(Patch(facecolor=NO_DATA, label="fewer than 30 listings"))
    city_ax.legend(handles=handles, title="THB per night", loc="upper left", bbox_to_anchor=(0, -0.02),
                   title_fontsize=9, alignment="left", handlelength=1.2, handleheight=1.0, ncol=2,
                   columnspacing=1.0, borderaxespad=0)
    save(fig, "01_district_prices.png")


# 2. revenue concentration ------------------------------------------------------
def revenue_deciles():
    d = pd.read_csv(RES / "occ_revenue_deciles.csv")
    fig, ax = figure(
        10, 5.4,
        f"The top 10% of listings earn {d.pct_of_revenue[0]:.0f}% of estimated revenue",
        "Active listings in Sep 2026 ranked by estimated revenue over the last 12 months, split into ten equal groups.",
    )
    x = np.arange(len(d))
    colours = [BLUE if i == 0 else GREY for i in range(len(d))]
    ax.bar(x, d.pct_of_revenue, width=0.6, color=colours)
    for i in (0, 1):
        ax.text(x[i], d.pct_of_revenue[i] + 0.8, f"{d.pct_of_revenue[i]:.1f}%",
                ha="center", va="bottom", fontsize=9.5, color=INK)
    bottom_half = d.pct_of_revenue[5:].sum()
    ax.annotate(f"Bottom half together: {bottom_half:.1f}%", xy=(7, 6.5), ha="center",
                fontsize=9.5, color=INK_2)
    ax.plot([5 - 0.3, 9 + 0.3], [5.5, 5.5], color=MUTED, lw=1)
    ax.set_xticks(x, ["Top 10%"] + [f"{10 * i}-{10 * (i + 1)}%" for i in range(1, 10)])
    ax.set_ylabel("Share of estimated revenue")
    ax.yaxis.set_major_formatter(pct)
    ax.set_ylim(0, 48)
    ax.grid(axis="y")
    ax.set_axisbelow(True)
    ax.spines["left"].set_visible(False)
    save(fig, "02_revenue_concentration.png")


# 3. price by district ----------------------------------------------------------
def price_by_district():
    p = pd.read_csv(RES / "price_by_district.csv")
    p = p[p.price_rank.notna()].sort_values("median_thb")
    city = city_median_price()
    cheap, dear = p.iloc[0], p.iloc[-1]
    fig, ax = figure(
        10, 10.5,
        f"Prices by district: a {dear.median_thb / cheap.median_thb:.1f}x gap from {name(cheap.district)} to {name(dear.district)}",
        "Median asking price per night (dot) and middle 50% of listings (bar). Active entire homes, 1 to 6 night minimum,\n"
        "Sep 2026. Districts with 30+ listings.",
    )
    y = np.arange(len(p))
    ax.hlines(y, p.p25_thb, p.p75_thb, color=BLUE_LIGHT, lw=5, capstyle="round")
    ax.scatter(p.median_thb, y, s=42, color=BLUE, zorder=3, edgecolor=SURFACE, linewidth=1.5)
    ax.axvline(city, color=MUTED, lw=1, zorder=1)
    ax.text(city + 40, len(p) - 0.3, f"City median {city:,.0f}", fontsize=8.5, color=INK_2, va="bottom")
    ax.set_yticks(y, [f"{name(d)}  ({n:,})" for d, n in zip(p.district, p.listings)])
    ax.set_xlabel("THB per night  (listings in brackets)")
    ax.xaxis.set_major_formatter(lambda v, _: f"{v:,.0f}")
    ax.set_xlim(0, 6600)
    ax.set_ylim(-0.8, len(p) - 0.1)
    ax.grid(axis="x")
    ax.set_axisbelow(True)
    ax.spines["left"].set_visible(False)
    for d in (dear.district, cheap.district):
        r = p[p.district == d].iloc[0]
        i = list(p.district).index(d)
        ax.text(r.p75_thb + 120, i, f"{r.median_thb:,.0f}", va="center", fontsize=9, color=INK)
    save(fig, "03_price_by_district.png")


# 4. nightly vs monthly ---------------------------------------------------------
def nightly_vs_monthly():
    s = pd.read_csv(RES / "price_short_vs_monthly.csv")
    s = s[s.monthly_discount_pct > 0].sort_values("break_even_occ_pct")
    fig, ax = figure(
        10, 6.8,
        f"A nightly 1-bed needs {s.break_even_occ_pct.min():.0f} to {s.break_even_occ_pct.max():.0f}% occupancy to match a monthly let. "
        f"The typical one gets {s.nightly_median_occ_pct.min():.0f} to {s.nightly_median_occ_pct.max():.0f}%",
        "1-bedroom entire homes, Sep 2026. Break-even = monthly price per night / nightly price per night, before\n"
        "cleaning, platform fees and utilities. Districts with 30+ nightly and 30+ monthly listings.",
        note="Prices: every priced 1-bed, active or not. Occupancy: active nightly 1-beds. Chatuchak and Bang Phlat are left out:\n"
             "their monthly 1-beds are priced above the nightly ones, so the comparison doesn't hold.",
    )
    y = np.arange(len(s))
    ax.hlines(y, s.nightly_median_occ_pct, s.break_even_occ_pct, color=GRID, lw=3)
    ax.scatter(s.nightly_median_occ_pct, y, s=60, color=BLUE, zorder=3, edgecolor=SURFACE,
               linewidth=1.5, label="Median nightly listing's occupancy")
    ax.scatter(s.break_even_occ_pct, y, s=60, color=ORANGE, zorder=3, edgecolor=SURFACE,
               linewidth=1.5, label="Occupancy needed to match monthly rent")
    top = len(s) - 1
    r = s.iloc[-1]
    ax.text(r.nightly_median_occ_pct, top + 0.45, f"{r.nightly_median_occ_pct:.0f}%",
            ha="center", va="bottom", fontsize=8.5, color=INK_2)
    ax.text(r.break_even_occ_pct, top + 0.45, f"{r.break_even_occ_pct:.0f}%",
            ha="center", va="bottom", fontsize=8.5, color=INK_2)
    ax.set_yticks(y, [name(d) for d in s.district])
    ax.set_xlim(0, 80)
    ax.set_ylim(-0.7, len(s) + 0.2)
    ax.xaxis.set_major_formatter(pct)
    ax.set_xlabel("Share of nights booked in a year")
    ax.grid(axis="x")
    ax.set_axisbelow(True)
    ax.spines["left"].set_visible(False)
    ax.legend(loc="lower left", bbox_to_anchor=(0, 1.04), ncol=2, handletextpad=0.3, borderaxespad=0)
    save(fig, "04_nightly_vs_monthly.png")


# 5. host tiers -----------------------------------------------------------------
def host_tiers():
    t = pd.read_csv(DASH / "host_tiers.csv")
    big = t.set_index("tier").loc["100+"]
    fig, ax = figure(
        10, 6.2,
        f"The biggest operators hold {big.pct_of_listings:.1f}% of listings but earn {big.pct_of_revenue:.1f}% of revenue",
        "Host accounts grouped by how many listings they run, Sep 2026. Two thirds of the 100+ tier's listings\n"
        "had no review in a year. Counting active listings only, their share of supply and revenue roughly match.",
    )
    series = [("pct_of_listings", "All listings", GREY),
              ("pct_of_active_listings", "Active listings (1+ review in 12 months)", BLUE_LIGHT),
              ("pct_of_revenue", "Estimated revenue", BLUE)]
    tiers = list(t.tier)[::-1]
    y = np.arange(len(tiers))
    h = 0.24
    for k, (col, label, c) in enumerate(series):
        vals = t.set_index("tier").loc[tiers, col].values
        pos = y + (1 - k) * (h + 0.03)
        ax.barh(pos, vals, height=h, color=c, label=label)
        for v, py in zip(vals, pos):
            ax.text(v + 0.4, py, f"{v:.1f}%", va="center", fontsize=8, color=INK_2)
    ax.set_yticks(y, [f"{x} listings" if x != "1 listing" else x for x in tiers])
    ax.xaxis.set_major_formatter(pct)
    ax.set_xlim(0, 40)
    ax.set_xlabel("Share of the city total")
    ax.grid(axis="x")
    ax.set_axisbelow(True)
    ax.spines["left"].set_visible(False)
    handles, labels = ax.get_legend_handles_labels()
    ax.legend(handles, labels, loc="lower right", ncol=1)
    save(fig, "05_host_tiers.png")


# 6. supply vs demand -----------------------------------------------------------
def supply_demand():
    m = pd.read_csv(DASH / "monthly.csv", parse_dates=["snapshot_date"])
    base = m[m.snapshot_date == "2025-09-26"].iloc[0]
    m["demand"] = 100 * m.reviews_last_12m / base.reviews_last_12m
    m["supply"] = 100 * m.active_listings / base.active_listings
    full = m[m.is_complete]
    last = full.iloc[-1]

    fig, ax = figure(
        10, 5.8,
        f"Over the last year demand grew {last.demand - 100:.1f}% and supply {last.supply - 100:.1f}%, "
        "so bookings per listing held flat",
        "Index, Sep 2025 = 100. Demand = reviews in the trailing 12 months, summed across each snapshot.\n"
        "Supply = listings with at least one review in the last 12 months. Feb to Apr 2026 were partial scrapes and\n"
        "May is missing, so the dashed line joins the last full snapshot before the gap to the first one after.",
    )
    # the gap runs from the last full snapshot before the first partial one to the
    # first full snapshot after the last partial one
    partial = m.index[~m.is_complete]
    before, after = m.loc[:partial.min() - 1], m.loc[partial.max() + 1:]
    gap_from = before[before.is_complete].iloc[-1]
    gap_to = after[after.is_complete].iloc[0]
    ax.axvspan(gap_from.snapshot_date, gap_to.snapshot_date, color=NO_DATA, lw=0)
    ax.text(gap_from.snapshot_date + (gap_to.snapshot_date - gap_from.snapshot_date) / 2, 115.2, "partial scrapes",
            ha="center", va="top", fontsize=8.5, color=INK_2)
    for col, label, c in [("demand", "Demand: reviews, last 12 months", ORANGE),
                          ("supply", "Supply: active listings", BLUE)]:
        # solid on each side, meeting the band's edges; dashed across it
        for k, part in enumerate((full[full.snapshot_date <= gap_from.snapshot_date],
                                  full[full.snapshot_date >= gap_to.snapshot_date])):
            ax.plot(part.snapshot_date, part[col], color=c, lw=2, solid_capstyle="round",
                    label=label if k == 0 else None)
        ax.plot([gap_from.snapshot_date, gap_to.snapshot_date], [gap_from[col], gap_to[col]], color=c, lw=1.5,
                linestyle=(0, (4, 4)))
        last = full.iloc[-1]
        ax.scatter([last.snapshot_date], [last[col]], s=36, color=c, zorder=3,
                   edgecolor=SURFACE, linewidth=1.5)
    ax.scatter([base.snapshot_date], [100], s=36, color=INK_2, zorder=3, edgecolor=SURFACE, linewidth=1.5)
    ax.annotate("Sep 2025 = 100", (base.snapshot_date, 100), xytext=(0, -16),
                textcoords="offset points", ha="center", fontsize=8.5, color=INK_2)
    last = full.iloc[-1]
    ax.text(last.snapshot_date + pd.Timedelta(days=12), last.demand + 0.9,
            f"+{last.demand - 100:.1f}%", fontsize=9, color=INK, va="center")
    ax.text(last.snapshot_date + pd.Timedelta(days=12), last.supply - 0.9,
            f"+{last.supply - 100:.1f}%", fontsize=9, color=INK, va="center")
    ax.set_ylim(78, 116)
    ax.set_xlim(pd.Timestamp("2024-09-01"), pd.Timestamp("2026-11-10"))
    ax.grid(axis="y")
    ax.set_axisbelow(True)
    ax.spines["left"].set_visible(False)
    ax.xaxis.set_major_formatter(matplotlib.dates.DateFormatter("%b %Y"))
    ax.xaxis.set_major_locator(matplotlib.dates.MonthLocator(bymonth=(3, 9)))
    ax.legend(loc="upper left")
    save(fig, "06_supply_vs_demand.png")


# 7. data quality: the two scrape changes ---------------------------------------
def scrape_changes():
    cov = pd.read_csv(RES / "dq_snapshot_coverage.csv", parse_dates=["snapshot_date"])
    dorm = pd.read_csv(RES / "dq_dormant_listings.csv", parse_dates=["snapshot_date"])
    partial = cov[~cov.is_complete].coverage * 100
    fig, axes = figure(
        10, 5.6,
        "Two scraper changes that look like market moves",
        f"Left: three snapshots caught only {partial.min():.0f} to {partial.max():.0f}% of listings and would read as a crash. Right: from Feb 2026 the\n"
        "scrape stops returning most dormant listings, which faked half of a rise in professional hosts.",
        note="Dormant = calendar blocked for the next 365 days and no reviews in 12 months.",
        ncols=2,
    )

    x = np.arange(len(cov))
    ticks = [i for i, d in enumerate(cov.snapshot_date) if d.month in (1, 7) or i == 0]
    labels = [cov.snapshot_date[i].strftime("%b\n%Y") for i in ticks]

    a = axes[0]
    a.bar(x, cov.listings, width=0.7, color=[GREY if c else ORANGE for c in cov.is_complete])
    a.set_title("Listings per snapshot", loc="left", fontsize=10.5, fontweight="bold", pad=10)
    a.yaxis.set_major_formatter(lambda v, _: f"{v / 1000:.0f}K" if v else "0")
    a.text(x[18], cov.listings[17] + 700, "partial", ha="center", fontsize=8.5, color=INK_2)

    b = axes[1]
    after = dorm.snapshot_date >= "2026-02-01"
    b.bar(x, dorm.dormant, width=0.7, color=[ORANGE if f else GREY for f in after])
    b.set_title("Dormant listings per snapshot", loc="left", fontsize=10.5, fontweight="bold", pad=10)
    b.yaxis.set_major_formatter(lambda v, _: f"{v / 1000:.1f}K" if v else "0")
    b.text(x[21], dorm.dormant[22] + 160, "scope\nchanged", ha="center", fontsize=8.5,
           color=INK_2, linespacing=1.2)

    for a_ in axes:
        a_.set_xticks(ticks, labels)
        a_.grid(axis="y")
        a_.set_axisbelow(True)
        a_.spines["left"].set_visible(False)
        a_.set_xlim(-0.8, len(cov) - 0.2)
    save(fig, "07_scrape_changes.png")


# 8. growth measured two ways ---------------------------------------------------
def growth_two_ways():
    g = pd.read_csv(RES / "trend_growth_two_ways.csv")
    missing = pd.read_csv(RES / "trend_review_survivorship.csv").pct_of_history_missing.iloc[0]
    fig, ax = figure(
        10, 3.5,
        f"Counting only surviving listings puts demand growth at {g.growth_pct[0]:.0f}%, not {g.growth_pct[1]:.1f}%",
        "Growth in reviews, latest 12 months vs the 12 before. The reviews file only covers listings still live in Sep 2026;\n"
        f"listings that left since Sep 2024 took at least {missing:.1f}% of the review history with them.",
    )
    labels = ["Reviews file\n(survivors only)", "Snapshot panel\n(every listing live at the time)"]
    vals = g.growth_pct.values
    y = np.array([1, 0])
    ax.barh(y, vals, height=0.34, color=[GREY, BLUE])
    for v, yy in zip(vals, y):
        ax.text(v + 0.4, yy, f"+{v:.1f}%", va="center", fontsize=11, fontweight="bold")
    ax.set_yticks(y, labels)
    ax.set_xlim(0, 28)
    ax.set_xticks([])
    ax.spines["left"].set_visible(False)
    ax.spines["bottom"].set_visible(False)
    save(fig, "08_growth_two_ways.png")


# 9. seasonality ----------------------------------------------------------------
def seasonality():
    s = pd.read_csv(RES / "trend_seasonality.csv")
    month = lambda i: pd.Timestamp(2025, int(i), 1).strftime("%B")
    peak = month(s.loc[s.season_index.idxmax(), "month_of_year"])
    low = month(s.loc[s.season_index.idxmin(), "month_of_year"])
    fig, ax = figure(
        10, 5.2,
        f"{peak} is the busiest month, {low} the quietest",
        "Reviews per month against a centred 12-month trend, 2023 to 2025, so growth doesn't tilt the pattern.\n"
        "100 = an average month. Lines show the lowest and highest of the three years.",
    )
    x = np.arange(12)
    above = s.season_index >= 100
    ax.bar(x, s.season_index - 100, bottom=100, width=0.55,
           color=[BLUE if a else GREY for a in above])
    ax.vlines(x, s.lowest_year, s.highest_year, color=INK_2, lw=1.2)
    ax.axhline(100, color=MUTED, lw=1)
    for i in (s.season_index.idxmax(), s.season_index.idxmin()):
        v = s.season_index[i]
        off = s.highest_year[i] + 1.5 if v >= 100 else s.lowest_year[i] - 1.5
        ax.text(x[i], off, f"{v:.0f}", ha="center", va="bottom" if v >= 100 else "top", fontsize=9.5)
    ax.set_xticks(x, ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"])
    ax.set_ylim(70, 148)
    ax.grid(axis="y")
    ax.set_axisbelow(True)
    ax.spines["left"].set_visible(False)
    ax.spines["bottom"].set_visible(False)
    save(fig, "09_seasonality.png")


# 10. price index ---------------------------------------------------------------
def price_index():
    p = pd.read_csv(RES / "trend_price_index.csv", parse_dates=["snapshot_date"])
    listed = p[p.price_basis == "listed"].reset_index(drop=True)
    top = listed.price_index.idxmax()
    back = listed[(listed.index > top) & (listed.price_index < 101)].iloc[0]
    fig, axes = figure(
        10, 5.2,
        f"Asking prices rose {listed.price_index[top] - 100:.0f}% into the {listed.snapshot_date[top].year} high season "
        f"and were back to the start by {back.snapshot_date:%B}",
        "Same-listing price index: each listing compared only with itself, same minimum stay, back-to-back complete\n"
        "snapshots. The price field changed meaning in 2026, so the two series are kept apart.",
        note="No usable price Dec 2025 to Feb 2026; Mar and Apr 2026 were partial scrapes.",
        ncols=2, sharey=True, gridspec_kw={"width_ratios": [15, 4]},
    )
    for a, basis, title in [(axes[0], "listed", "Listed nightly price, Sep 2024 = 100"),
                            (axes[1], "quote", "Quoted price,\nJun 2026 = 100")]:
        d = p[p.price_basis == basis]
        a.plot(d.snapshot_date, d.price_index, color=BLUE, lw=2, marker="o", ms=4.5,
               markeredgecolor=SURFACE, markeredgewidth=1.2)
        a.axhline(100, color=MUTED, lw=1)
        a.set_title(title, loc="left", fontsize=10, fontweight="bold", pad=8)
        a.grid(axis="y")
        a.set_axisbelow(True)
        a.spines["left"].set_visible(False)
        a.xaxis.set_major_formatter(matplotlib.dates.DateFormatter("%b\n%Y"))
    axes[0].xaxis.set_major_locator(matplotlib.dates.MonthLocator(bymonth=(1, 4, 7, 10)))
    axes[1].xaxis.set_major_locator(matplotlib.dates.MonthLocator(bymonth=(7, 9)))
    peak = p[p.price_basis == "listed"].sort_values("price_index").iloc[-1]
    axes[0].annotate(f"{peak.price_index:.0f}", (peak.snapshot_date, peak.price_index), xytext=(0, 8),
                     textcoords="offset points", ha="center", fontsize=9.5)
    axes[0].set_ylim(90, 128)
    save(fig, "10_price_index.png")


# 11. amenity premium, naive vs like-for-like -----------------------------------
def amenity_premium():
    a = pd.read_csv(RES / "price_amenity_premium.csv")
    a = a.sort_values("premium_plus_property_type_pct")
    pool = a.set_index("amenity").loc["pool"]
    fig, ax = figure(
        10, 4.9,
        f"Like for like, listings with a pool price {pool.premium_plus_property_type_pct:.0f}% higher, not {pool.naive_premium_pct:.0f}%",
        "Price premium for listings with each amenity. Naive = all listings with vs without. Like-for-like = medians\n"
        "compared inside the same district, bedroom count and property type, then averaged. Every priced entire home\n"
        "with a 1 to 6 night minimum, active or not, Sep 2026.",
        note="Read the pool figure as a building premium: in Bangkok a pool mostly means a newer condo tower.",
    )
    y = np.arange(len(a))
    h = 0.32
    ax.barh(y + h / 2 + 0.02, a.naive_premium_pct, height=h, color=GREY, label="Naive comparison")
    ax.barh(y - h / 2 - 0.02, a.premium_plus_property_type_pct, height=h, color=BLUE, label="Like-for-like")
    for yy, v1, v2 in zip(y, a.naive_premium_pct, a.premium_plus_property_type_pct):
        for v, off in ((v1, h / 2 + 0.02), (v2, -h / 2 - 0.02)):
            ax.text(v + (0.5 if v >= 0 else -0.5), yy + off, f"{v:+.0f}%", va="center",
                    ha="left" if v >= 0 else "right", fontsize=8.5, color=INK_2)
    ax.axvline(0, color=AXIS, lw=1)
    ax.set_yticks(y, [x.capitalize() for x in a.amenity])
    ax.set_xlim(-10, 33)
    ax.xaxis.set_major_formatter(lambda v, _: f"{v:+.0f}%" if v else "0")
    ax.grid(axis="x")
    ax.set_axisbelow(True)
    ax.spines["left"].set_visible(False)
    ax.legend(loc="lower right")
    save(fig, "11_amenity_premium.png")


if __name__ == "__main__":
    district_map()
    revenue_deciles()
    price_by_district()
    nightly_vs_monthly()
    host_tiers()
    supply_demand()
    scrape_changes()
    growth_two_ways()
    seasonality()
    price_index()
    amenity_premium()
