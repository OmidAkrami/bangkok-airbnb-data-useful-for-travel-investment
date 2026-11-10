-- 02_data_quality.sql
-- Checks I ran before trusting any number. Each one is a view so the
-- output lands in results/ and I can point at it.


-- 1. Coverage per snapshot (logic lives in 01_staging.sql).
-- Feb/Mar/Apr 2026 are partial scrapes. There is no May 2026 snapshot at all.
create or replace view dq_snapshot_coverage as
select
    snapshot_date,
    listings,
    priced,
    holes,
    coverage,
    prev_still_present_pct,
    is_complete,
    -- gap since previous snapshot, to catch missing months
    snapshot_date - lag(snapshot_date) over (order by snapshot_date) as days_since_prev
from snapshots;


-- 1b. The partial scrapes aren't a random sample either. Mar and Apr 2026 have
-- 6 and 1 listings with a 30+ night minimum, against 13-15% in every full
-- snapshot. Looks like that crawl only found listings bookable for short dates,
-- so anything computed on those two months leans towards short lets.
create or replace view dq_partial_scrape_profile as
select
    l.snapshot_date,
    s.is_complete,
    count(*)                                                        as listings,
    round(100.0 * avg(case when l.min_nights >= 30 then 1 else 0 end), 1)              as pct_min_30_plus,
    round(100.0 * avg(case when l.room_type = 'Entire home/apt' then 1 else 0 end), 1) as pct_entire_home,
    round(100.0 * avg(case when l.reviews_ltm > 0 then 1 else 0 end), 1)               as pct_active
from stg_listings l
join snapshots s on s.snapshot_date = l.snapshot_date
group by l.snapshot_date, s.is_complete
order by l.snapshot_date;


-- 1c. Second scope change, and the sneakier one. Until Jan 2026 every snapshot
-- had ~3,000 dormant listings (calendar blocked all year, no reviews in 12 months).
-- From Feb 2026 most of them are gone from the scrape, and they never come back.
-- 3,359 listings were last seen in Jan 2026, 73% of them fully blocked. For the
-- leavers of every other month that share is between 2% and 15%. I read that
-- as a change in what gets scraped. Consequence: total listing and host counts
-- before and after Feb 2026 are not comparable. Active listings (reviewed in the last
-- 12 months) are, so trends in 05 and 06 use those.
create or replace view dq_dormant_listings as
select
    l.snapshot_date,
    s.is_complete,
    count(*)                                                        as listings,
    count(*) filter (where l.avail_365 = 0 and l.reviews_ltm = 0)  as dormant,
    round(100.0 * count(*) filter (where l.avail_365 = 0 and l.reviews_ltm = 0) / count(*), 1) as pct_dormant
from stg_listings l
join snapshots s on s.snapshot_date = l.snapshot_date
group by l.snapshot_date, s.is_complete
order by l.snapshot_date;


-- 1d. Where did the missing listings go? For each snapshot: listings that were
-- in the previous snapshot but not in this one, and how many of them turn up
-- again later. A real exit doesn't come back; a gap in the scrape does.
-- Feb to Mar 2026: 10,271 dropped out and 8,973 came back.
create or replace view dq_dropouts as
with s as (
    select snapshot_date, lag(snapshot_date) over (order by snapshot_date) as prev_date
    from snapshots
),
last_seen as (
    select listing_id, max(snapshot_date) as last_date
    from stg_listings
    group by listing_id
),
dropped as (
    select s.snapshot_date, p.listing_id
    from s
    join stg_listings p on p.snapshot_date = s.prev_date
    where not exists (
        select 1 from stg_listings c
        where c.listing_id = p.listing_id
          and c.snapshot_date = s.snapshot_date
    )
)
select
    d.snapshot_date,
    sn.is_complete,
    count(*)                                                        as dropped_out,
    count(*) filter (where ls.last_date > d.snapshot_date)          as came_back_later,
    round(100.0 * count(*) filter (where ls.last_date > d.snapshot_date) / count(*), 1) as pct_came_back
from dropped d
join last_seen ls on ls.listing_id = d.listing_id
join snapshots sn on sn.snapshot_date = d.snapshot_date
group by d.snapshot_date, sn.is_complete
order by d.snapshot_date;


-- 2. Fill rate of the fields I rely on, per snapshot.
-- This is where the schema changes show up: no Inside Airbnb occupancy
-- estimate before 2025, no price Dec 2025 to Feb 2026, no host_since from Dec 2025.
-- The raw bathrooms column is empty in Sep 2026 too, but staging falls back to
-- bathrooms_text so it doesn't show here.
create or replace view dq_fill_rates as
select
    snapshot_date,
    count(*)                                              as listings,
    round(100.0 * count(price)          / count(*), 1)    as pct_price,
    round(100.0 * count(bedrooms)       / count(*), 1)    as pct_bedrooms,
    round(100.0 * count(bathrooms)      / count(*), 1)    as pct_bathrooms,
    round(100.0 * count(rating)         / count(*), 1)    as pct_rating,
    round(100.0 * count(iab_occ_nights) / count(*), 1)    as pct_iab_occupancy,
    round(100.0 * count(host_since)     / count(*), 1)    as pct_host_since
from stg_listings
group by snapshot_date
order by snapshot_date;


-- 3. Price spread per snapshot. Medians are stable, the max is junk.
create or replace view dq_price_spread as
select
    snapshot_date,
    price_basis,
    count(price)                                                   as priced,
    percentile_cont(0.01) within group (order by price)            as p01,
    percentile_cont(0.25) within group (order by price)            as p25,
    percentile_cont(0.50) within group (order by price)            as median,
    percentile_cont(0.75) within group (order by price)            as p75,
    percentile_cont(0.99) within group (order by price)            as p99,
    max(price)                                                     as max_price,
    count(*) filter (where price is not null and not price_ok)     as flagged
from stg_listings
where price is not null
group by snapshot_date, price_basis
order by snapshot_date;


-- 4. Logic checks. Any non-zero count is something to explain or exclude.
create or replace view dq_logic_checks as
select 'duplicate listing_id within a snapshot' as check_name,
       (select count(*) - count(distinct snapshot_date || '-' || listing_id) from stg_listings) as rows_failing
union all
select 'last_review before first_review',
       (select count(*) from stg_listings where last_review < first_review)
union all
select 'reviews_ltm greater than reviews_total',
       (select count(*) from stg_listings where reviews_ltm > reviews_total)
union all
select 'min_nights greater than max_nights',
       (select count(*) from stg_listings where min_nights > max_nights)
union all
-- non-zero but harmless: a scrape takes several days, the folder date is day one.
-- largest gap is 11 days, nothing beyond that.
select 'last_review after the snapshot date',
       (select count(*) from stg_listings where last_review > snapshot_date)
union all
select 'last_review more than 14 days after the snapshot date',
       (select count(*) from stg_listings where last_review > snapshot_date + 14)
union all
-- also non-zero: 421 rows from 76 listings. 58 of those listings changed host
-- account at some point. Reviews stay with the listing, but host_since is the
-- new account's start date.
select 'first_review before host_since',
       (select count(*) from stg_listings where first_review < host_since)
union all
select 'coordinates outside greater Bangkok box',
       (select count(*) from stg_listings
        where lat not between 13.4 and 14.1 or lon not between 100.2 and 101.0)
union all
select 'price outside 200 to 100,000 THB',
       (select count(*) from stg_listings where price is not null and not price_ok);


-- 5. What is the new "quote" price actually quoting?
-- Turns out the quote length is the listing's minimum stay. So a listing with
-- min_nights = 30 shows a per-night price for a month-long booking, which
-- is usually discounted. Pricing analysis has to split short and monthly stays.
create or replace view dq_quote_window as
select
    case
        when quote_nights = greatest(min_nights, 1) then 'quote length = min_nights'
        when quote_nights > greatest(min_nights, 1) then 'quote longer than min_nights'
        else 'quote shorter than min_nights'
    end                                    as quote_vs_min_stay,
    count(*)                               as listings,
    round(100.0 * count(*) / sum(count(*)) over (), 1) as pct
from latest
where price_basis = 'quote'
group by 1
order by listings desc;


-- 6. Listings that look dead in the latest snapshot.
-- Fully blocked calendar plus no reviews in a year: probably not really trading.
create or replace view dq_dead_listings as
select
    case
        when avail_365 = 0   and reviews_ltm = 0 then 'blocked all year, no reviews in 12m'
        when avail_365 = 365 and reviews_ltm = 0 then 'open all year, no reviews in 12m'
        when reviews_ltm = 0                     then 'no reviews in 12m'
        else 'reviewed in last 12m'
    end                 as status,
    count(*)            as listings,
    round(100.0 * count(*) / sum(count(*)) over (), 1) as pct
from latest
group by 1
order by listings desc;


-- 7. Does the reviews file agree with the listing counters?
create or replace view dq_reviews_reconcile as
with file_counts as (
    select listing_id, count(*) as reviews_in_file
    from stg_reviews
    group by listing_id
)
select
    (select count(*) from stg_reviews)                               as review_rows,
    (select sum(reviews_total) from latest)                          as sum_reviews_total,
    count(*) filter (where f.reviews_in_file = l.reviews_total)      as listings_matching,
    count(*) filter (where f.reviews_in_file <> l.reviews_total)     as listings_off,
    count(*) filter (where f.listing_id is null and l.reviews_total > 0) as missing_from_file
from latest l
left join file_counts f on f.listing_id = l.listing_id;
