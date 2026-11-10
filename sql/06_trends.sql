-- 06_trends.sql
-- Month over month. Three sources, each with its own catch:
--   reviews file   full history back to 2011, but only for listings still alive
--                  in Sep 2026, so older months are undercounted (checked below).
--   snapshots      24 monthly scrapes, Sep 2024 to Sep 2026. No May 2026, and
--                  Feb to Apr 2026 are partial. Changes and YoY are computed
--                  between complete snapshots only. Views that list every
--                  snapshot keep the partial ones as flagged rows.
--   prices         two series that can't be joined (listed price until Nov 2025,
--                  quote price from Mar 2026). Measured as same-listing changes,
--                  complete snapshots only, so the quote series starts in Jun 2026.


-- month number that works in any SQL dialect: year * 12 + month
create or replace view snapshot_months as
select
    snapshot_date,
    is_complete,
    cast(extract(year from snapshot_date) * 12 + extract(month from snapshot_date) as int) as month_no
from snapshots;


-- 1. Reviews per month, with MoM, YoY and a 3 month rolling average.
-- A month spine first, so lag(12) really means 12 months back even if a month had zero reviews.
create or replace view trend_reviews_monthly as
with spine as (
    select cast(m as date) as month
    from generate_series(date '2016-01-01', date '2026-08-01', interval '1 month') as t(m)
),
counts as (
    select date_trunc('month', review_date) as month, count(*) as reviews
    from stg_reviews
    group by 1
),
filled as (
    select s.month, coalesce(c.reviews, 0) as reviews
    from spine s
    left join counts c on c.month = s.month
)
select
    month,
    reviews,
    round(100.0 * (reviews - lag(reviews) over w) / nullif(lag(reviews) over w, 0), 1)         as mom_pct,
    round(100.0 * (reviews - lag(reviews, 12) over w) / nullif(lag(reviews, 12) over w, 0), 1) as yoy_pct,
    round(avg(reviews) over (order by month rows between 2 preceding and current row))        as rolling_3m
from filled
window w as (order by month)
order by month;


-- 2. Seasonality, 2023-2025. Each month divided by a centred 12 month moving
-- average (the "2x12" one: 13 months with the two ends at half weight), then
-- averaged by calendar month and scaled so the average month = 100.
-- Each month's share of its calendar year doesn't work here: with reviews
-- growing 20-60% a year it inflates late-year months and deflates early ones,
-- and puts the peak in December when January is higher every year.
-- Review dates trail the actual stay by a week or two.
create or replace view trend_seasonality as
with ma as (
    select
        month,
        reviews,
        (sum(reviews) over (order by month rows between 6 preceding and 6 following)
           - 0.5 * lag(reviews, 6)  over (order by month)
           - 0.5 * lead(reviews, 6) over (order by month)) / 12.0  as trend,
        count(*) over (order by month rows between 6 preceding and 6 following) as months_in_window
    from trend_reviews_monthly
),
ratios as (
    select extract(month from month) as mon, reviews / trend as ratio
    from ma
    where month >= date '2023-01-01' and month < date '2026-01-01'
      and months_in_window = 13
),
by_month as (
    select mon, avg(ratio) as avg_ratio, min(ratio) as min_ratio, max(ratio) as max_ratio
    from ratios
    group by mon
)
select
    cast(mon as int)                                                as month_of_year,
    round(100 * avg_ratio / avg(avg_ratio) over ())                 as season_index,
    round(100 * min_ratio / avg(avg_ratio) over ())                 as lowest_year,
    round(100 * max_ratio / avg(avg_ratio) over ())                 as highest_year
from by_month
order by mon;


-- 3. How big is the survivorship gap in the reviews file?
-- Listings that dropped out before Sep 2026 take their reviews with them.
-- Their last known review count tells me how much history is missing.
create or replace view trend_review_survivorship as
with last_seen as (
    select listing_id, max(snapshot_date) as last_date
    from stg_listings
    group by listing_id
),
gone as (
    select l.listing_id, l.reviews_total, l.reviews_ltm
    from stg_listings l
    join last_seen s on s.listing_id = l.listing_id and s.last_date = l.snapshot_date
    where s.last_date < (select max(snapshot_date) from stg_listings)
)
select
    count(*)                                                        as listings_gone_since_sep_2024,
    sum(reviews_total)                                              as their_reviews,
    (select count(*) from stg_reviews)                              as reviews_in_file,
    round(100.0 * sum(reviews_total) / (sum(reviews_total) + (select count(*) from stg_reviews)), 1) as pct_of_history_missing
from gone;


-- 3b. Same question, put as growth. Last 12 full months vs the 12 before,
-- counted two ways. The gap between them is the survivorship bias.
create or replace view trend_growth_two_ways as
select
    'reviews file (Sep-Aug windows)'                                as method,
    sum(reviews) filter (where month between date '2024-09-01' and date '2025-08-01') as prior_12m,
    sum(reviews) filter (where month between date '2025-09-01' and date '2026-08-01') as last_12m,
    round(100.0 * sum(reviews) filter (where month between date '2025-09-01' and date '2026-08-01')
          / sum(reviews) filter (where month between date '2024-09-01' and date '2025-08-01') - 100, 1) as growth_pct
from trend_reviews_monthly
union all
select
    'snapshot panel (reviews_ltm, Sep 2025 vs Sep 2026)',
    sum(reviews_ltm) filter (where snapshot_date = date '2025-09-26'),
    sum(reviews_ltm) filter (where snapshot_date = date '2026-09-22'),
    round(100.0 * sum(reviews_ltm) filter (where snapshot_date = date '2026-09-22')
          / sum(reviews_ltm) filter (where snapshot_date = date '2025-09-26') - 100, 1)
from stg_listings;


-- 3c. Occupancy over time. Same model as 03_occupancy.sql, applied to every
-- snapshot (reviews_ltm and min_nights exist in all of them). Each point is a
-- trailing 12 month figure, so it moves slowly by design.
-- Watch out: the model multiplies reviews by min_nights, so if hosts shorten
-- their minimum stay, modelled occupancy drops even with the same bookings.
-- That's what happens in Dec 2025 (share of active listings with a 30+ night
-- minimum goes from 12% to 10%). reviews_per_active_listing doesn't have that
-- problem, which is why it's here too.
create or replace view trend_occupancy as
select
    l.snapshot_date,
    s.is_complete,
    count(*)                                                        as active_listings,
    round(sum(l.reviews_ltm) * 1.0 / count(*), 2)                   as reviews_per_active_listing,
    round(100.0 * avg(case when l.min_nights >= 30 then 1 else 0 end), 1) as pct_min_30_plus,
    round(100 * median(least(l.reviews_ltm * 2 * greatest(l.min_nights, 3), 255) / 365.0), 1) as median_occ_pct,
    round(100 * avg(least(l.reviews_ltm * 2 * greatest(l.min_nights, 3), 255) / 365.0), 1)    as avg_occ_pct,
    round(100.0 * avg(case when l.reviews_ltm * 2 * greatest(l.min_nights, 3) >= 0.5 * 365 then 1 else 0 end), 1) as pct_above_50
from stg_listings l
join snapshots s on s.snapshot_date = l.snapshot_date
where l.reviews_ltm > 0
group by l.snapshot_date, s.is_complete
order by l.snapshot_date;


-- 3d. Minimum stay changes between back-to-back snapshots, listings active in
-- both. The Dec 2025 step in modelled occupancy lines up with a wave of hosts
-- cutting their minimum stay: 2,035 that month against 264 the month before.
create or replace view trend_min_stay_changes as
with s as (
    select snapshot_date, lag(snapshot_date) over (order by snapshot_date) as prev_date
    from snapshots
)
select
    c.snapshot_date,
    sn.is_complete,
    count(*)                                                        as active_in_both,
    count(*) filter (where c.min_nights < p.min_nights)             as cut_min_stay,
    count(*) filter (where c.min_nights > p.min_nights)             as raised_min_stay
from s
join stg_listings c on c.snapshot_date = s.snapshot_date
join stg_listings p on p.snapshot_date = s.prev_date and p.listing_id = c.listing_id
join snapshots sn on sn.snapshot_date = c.snapshot_date
where c.reviews_ltm > 0
  and p.reviews_ltm > 0
group by c.snapshot_date, sn.is_complete
order by c.snapshot_date;


-- 4. Supply per snapshot: total, active, new, gone.
--   new  = first time this listing id appears (Sep 2024 skipped, everything is "new" there)
--   gone = seen in the previous snapshot and never again
-- change_vs_prev_complete skips partial snapshots so the Feb-Apr 2026 dip doesn't fake a crash.
-- Use the active column for anything across Feb 2026: total listings lost ~2,000
-- dormant units that month to a scraper change (dq_dormant_listings).
-- The Jun 2026 "new" number is inflated: it covers everything created since
-- January that the partial scrapes and the missing May snapshot didn't catch.
create or replace view trend_supply as
with seen as (
    select listing_id, min(snapshot_date) as first_seen, max(snapshot_date) as last_seen
    from stg_listings
    group by listing_id
),
prev as (
    select snapshot_date, lag(snapshot_date) over (order by snapshot_date) as prev_date
    from snapshots
),
per as (
    select
        l.snapshot_date,
        count(*)                                                    as listings,
        count(*) filter (where l.reviews_ltm > 0)                   as active_listings,
        count(*) filter (where s.first_seen = l.snapshot_date)      as new_listings
    from stg_listings l
    join seen s on s.listing_id = l.listing_id
    group by l.snapshot_date
),
gone as (
    select p.snapshot_date, count(*) as gone_listings
    from prev p
    join seen s on s.last_seen = p.prev_date
    group by p.snapshot_date
),
complete_only as (
    select
        per.snapshot_date,
        per.listings,
        per.active_listings,
        lag(per.listings) over (order by per.snapshot_date)         as prev_listings,
        lag(per.active_listings) over (order by per.snapshot_date)  as prev_active,
        lag(per.snapshot_date) over (order by per.snapshot_date)    as prev_complete_date
    from per
    join snapshots s on s.snapshot_date = per.snapshot_date
    where s.is_complete
)
select
    per.snapshot_date,
    s.is_complete,
    per.listings,
    per.active_listings,
    case when per.snapshot_date > date '2024-09-25' then per.new_listings end as new_listings,
    g.gone_listings,
    c.prev_complete_date,
    round(100.0 * (c.listings - c.prev_listings) / c.prev_listings, 1) as change_vs_prev_complete_pct,
    round(100.0 * (c.active_listings - c.prev_active) / c.prev_active, 1) as active_change_vs_prev_complete_pct
from per
join snapshots s on s.snapshot_date = per.snapshot_date
left join gone g on g.snapshot_date = per.snapshot_date
left join complete_only c on c.snapshot_date = per.snapshot_date
order by per.snapshot_date;


-- 5. Same-listing price index.
-- For each pair of back-to-back priced snapshots, take listings in both, same
-- price basis, same min_nights, valid price in both. Average log change per pair
-- (a geometric mean, the Jevons index), then chain it with a running sum.
-- Comparing the same listings to themselves means new luxury units entering
-- can't push the "price" up on their own.
-- Not the median change: a third or more of listings don't touch their price,
-- so the median comes out as 0 almost every month.
-- Changes bigger than 3x either way are dropped as data noise.
create or replace view trend_price_index as
with priced as (
    select snapshot_date, row_number() over (order by snapshot_date) as seq
    from snapshots
    where priced > 0 and is_complete
),
pairs as (
    select
        cur.snapshot_date,
        prv.snapshot_date                                           as prev_date,
        c.price_basis,
        ln(c.price / p.price)                                       as log_change,
        c.price = p.price                                           as unchanged
    from priced cur
    join priced prv on prv.seq = cur.seq - 1
    join stg_listings c on c.snapshot_date = cur.snapshot_date
    join stg_listings p on p.snapshot_date = prv.snapshot_date and p.listing_id = c.listing_id
    where c.price_ok and p.price_ok
      and c.price_basis = p.price_basis
      and c.min_nights = p.min_nights
),
per_pair as (
    select
        snapshot_date,
        prev_date,
        price_basis,
        count(*)                                                    as matched_listings,
        avg(log_change)                                             as avg_log_change,
        avg(case when unchanged then 1.0 else 0 end)                as share_unchanged,
        avg(case when log_change > 0 then 1.0 else 0 end)           as share_up,
        avg(case when log_change < 0 then 1.0 else 0 end)           as share_down
    from pairs
    where abs(log_change) < ln(3)
    group by snapshot_date, prev_date, price_basis
)
select
    snapshot_date,
    prev_date,
    price_basis,
    matched_listings,
    round(100 * (exp(avg_log_change) - 1), 2)                       as avg_change_pct,
    round(100 * share_unchanged, 1)                                 as pct_unchanged,
    round(100 * share_up, 1)                                        as pct_up,
    round(100 * share_down, 1)                                      as pct_down,
    round(100 * exp(sum(avg_log_change) over (partition by price_basis order by snapshot_date)), 1) as price_index
from per_pair
union all
-- base month of each series, so the line starts at 100
select min(prev_date), null, price_basis, null, null, null, null, null, 100.0
from per_pair
group by price_basis
order by snapshot_date;


-- 5b. Demand without the survivorship problem: every snapshot carries
-- reviews_ltm (reviews in the 12 months before the scrape) for every listing
-- live at that moment, including ones that later disappear. Summing it gives a
-- rolling 12 month review count straight from the panel.
create or replace view trend_demand_ltm as
with t as (
    select
        l.snapshot_date,
        s.is_complete,
        m.month_no,
        sum(l.reviews_ltm)                                          as reviews_last_12m,
        count(*) filter (where l.reviews_ltm > 0)                   as listings_with_reviews
    from stg_listings l
    join snapshots s on s.snapshot_date = l.snapshot_date
    join snapshot_months m on m.snapshot_date = l.snapshot_date
    group by l.snapshot_date, s.is_complete, m.month_no
)
select
    a.snapshot_date,
    a.is_complete,
    a.reviews_last_12m,
    a.listings_with_reviews,
    b.reviews_last_12m                                              as same_month_last_year,
    case when a.is_complete and b.is_complete
         then round(100.0 * (a.reviews_last_12m - b.reviews_last_12m) / b.reviews_last_12m, 1)
    end                                                             as yoy_pct
from t a
left join t b on b.month_no = a.month_no - 12
order by a.snapshot_date;


-- 6. Which districts grew? Sep 2025 vs Sep 2026, both full snapshots.
-- Ranked on active listings because of the dormant-listing change in Feb 2026.
-- Districts with 100+ active listings a year earlier, so a few listings can't
-- swing the percentage.
create or replace view trend_district_growth as
with a as (
    select district, count(*) as n, count(*) filter (where reviews_ltm > 0) as active
    from stg_listings where snapshot_date = date '2025-09-26' group by district
),
b as (
    select district, count(*) as n, count(*) filter (where reviews_ltm > 0) as active
    from stg_listings where snapshot_date = date '2026-09-22' group by district
)
select
    b.district,
    a.active                                                        as active_sep_2025,
    b.active                                                        as active_sep_2026,
    b.active - a.active                                             as active_change,
    round(100.0 * (b.active - a.active) / a.active, 1)              as active_change_pct,
    round(100.0 * (b.n - a.n) / a.n, 1)                             as all_listings_change_pct,
    rank() over (order by 1.0 * (b.active - a.active) / a.active desc) as growth_rank
from b
join a on a.district = b.district
where a.active >= 100
order by growth_rank;


-- 6b. Is a district's growth one operator? Listings active in Sep 2026 that
-- weren't active in Sep 2025, and how many of those sit with the biggest
-- single host. In Thon Buri one host has 36 of the 180.
create or replace view trend_district_new_listings as
with newly as (
    select l.district, l.host_id
    from stg_listings l
    where l.snapshot_date = date '2026-09-22'
      and l.reviews_ltm > 0
      and not exists (
          select 1 from stg_listings b
          where b.listing_id = l.listing_id
            and b.snapshot_date = date '2025-09-26'
            and b.reviews_ltm > 0
      )
),
by_host as (
    select district, host_id, count(*) as n
    from newly
    group by district, host_id
)
select
    g.district,
    g.active_change,
    sum(h.n)                                                        as newly_active,
    max(h.n)                                                        as top_host_newly_active,
    round(100.0 * max(h.n) / sum(h.n), 1)                           as top_host_pct
from trend_district_growth g
join by_host h on h.district = g.district
group by g.district, g.active_change, g.growth_rank
order by g.growth_rank;


-- 7. Cohort retention. Listings grouped by the month they first appeared
-- (Oct 2024 to Sep 2025). What share is still listed 3, 6 and 12 months later?
-- Null where the target month is missing or a partial snapshot.
-- Anything measured after Feb 2026 is pulled down a bit by the dormant-listing
-- scope change, so the last column is a floor.
-- "New" means first seen in the panel. The Oct 2024 cohort includes a few
-- older listings that were just missing from Sep 2024 (9% had a first review
-- 90+ days before, vs 3-5% for later cohorts).
create or replace view trend_cohort_retention as
with first_seen as (
    select listing_id, min(snapshot_date) as cohort_date
    from stg_listings
    group by listing_id
),
cohorts as (
    select f.listing_id, f.cohort_date, m.month_no as cohort_month
    from first_seen f
    join snapshot_months m on m.snapshot_date = f.cohort_date
    where f.cohort_date between date '2024-10-01' and date '2025-09-30'
),
sizes as (
    select cohort_date, cohort_month, count(*) as cohort_size
    from cohorts
    group by cohort_date, cohort_month
),
retained as (
    -- how many of each cohort are listed N months later
    select c.cohort_date, m.month_no - c.cohort_month as months_after, count(*) as still_listed
    from cohorts c
    join stg_listings l on l.listing_id = c.listing_id
    join snapshot_months m on m.snapshot_date = l.snapshot_date
    where m.is_complete
    group by c.cohort_date, m.month_no - c.cohort_month
),
latest_month as (
    select max(month_no) as month_no from snapshot_months
)
select
    s.cohort_date,
    s.cohort_size,
    max(case when r.months_after = 3  then round(100.0 * r.still_listed / s.cohort_size, 1) end) as m3_pct,
    max(case when r.months_after = 6  then round(100.0 * r.still_listed / s.cohort_size, 1) end) as m6_pct,
    max(case when r.months_after = 12 then round(100.0 * r.still_listed / s.cohort_size, 1) end) as m12_pct,
    max(case when r.months_after = lm.month_no - s.cohort_month
             then round(100.0 * r.still_listed / s.cohort_size, 1) end)                        as still_listed_sep_2026_pct
from sizes s
cross join latest_month lm
left join retained r on r.cohort_date = s.cohort_date
group by s.cohort_date, s.cohort_size, s.cohort_month, lm.month_no
order by s.cohort_date;
