-- 01_staging.sql
-- Typed and cleaned tables. Rules below came out of the checks in 02_data_quality.sql.
--
--   price      text like '$1,250.00'. The $ is just formatting, the values are THB.
--              Dec 2025, Jan 2026 and Feb 2026 have no price at all.
--   price_basis  up to Nov 2025 price is the listed nightly price.
--              From Mar 2026 it's a quote: per-night price for a stay of min_nights
--              starting a few days after the scrape. Different measure, so it gets
--              its own label and I never compare across the two.
--   outliers   < 200 or > 100,000 THB a night gets flagged, not deleted.
--              Some hosts park listings at 1,000,000 to block bookings.

create or replace table stg_listings as
with typed as (
select
    cast(snapshot as date)                                    as snapshot_date,
    cast(id as bigint)                                        as listing_id,
    cast(host_id as bigint)                                   as host_id,
    host_name,
    try_cast(host_since as date)                              as host_since,
    coalesce(host_is_superhost = 't', false)                  as is_superhost,
    neighbourhood_cleansed                                    as district,
    cast(latitude as double)                                  as lat,
    cast(longitude as double)                                 as lon,
    property_type,
    room_type,
    try_cast(accommodates as int)                             as guests,
    cast(try_cast(bedrooms as double) as int)                 as bedrooms,
    coalesce(
        try_cast(bathrooms as double),
        try_cast(regexp_extract(bathrooms_text, '[0-9.]+') as double),
        case when lower(bathrooms_text) like '%half%' then 0.5 end
    )                                                         as bathrooms,

    try_cast(replace(replace(price, '$', ''), ',', '') as decimal(12, 2)) as price,
    case
        when price is null then 'none'
        when price_quote_checkin_date is null then 'listed'
        else 'quote'
    end                                                       as price_basis,
    datediff('day', try_cast(price_quote_checkin_date as date),
                    try_cast(price_quote_checkout_date as date)) as quote_nights,

    try_cast(minimum_nights as int)                           as min_nights,
    try_cast(maximum_nights as int)                           as max_nights,
    try_cast(availability_30 as int)                          as avail_30,
    try_cast(availability_90 as int)                          as avail_90,
    try_cast(availability_365 as int)                         as avail_365,
    try_cast(number_of_reviews as int)                        as reviews_total,
    try_cast(number_of_reviews_ltm as int)                    as reviews_ltm,
    try_cast(first_review as date)                            as first_review,
    try_cast(last_review as date)                             as last_review,
    try_cast(review_scores_rating as double)                  as rating,
    try_cast(review_scores_location as double)                as rating_location,
    coalesce(instant_bookable = 't', false)                   as instant_bookable,
    try_cast(calculated_host_listings_count as int)           as host_listings,
    try_cast(estimated_occupancy_l365d as int)                as iab_occ_nights,
    try_cast(estimated_revenue_l365d as double)               as iab_revenue,

    -- a few amenity flags. 'pool table', 'pool view' and fridge brands
    -- (Whirlpool, Worldpool) also contain 'pool', so they get stripped first
    regexp_matches(
        regexp_replace(lower(coalesce(amenities, '')), 'pool table|pool view|whirlpool|worldpool', '', 'g'),
        'pool')                                                                       as has_pool,
    regexp_matches(lower(coalesce(amenities, '')), 'gym|fitness')                     as has_gym,
    regexp_matches(lower(coalesce(amenities, '')), 'dedicated workspace')             as has_workspace,
    regexp_matches(lower(coalesce(amenities, '')), 'self check-in')                   as has_self_checkin
from raw_listings
)
select
    *,
    coalesce(price between 200 and 100000, false) as price_ok
from typed;


-- Snapshot list with two coverage checks.
-- holes: a listing that shows up before AND after a snapshot but is missing
--   from it. A normal month has a few hundred (people snooze listings).
--   Feb, Mar and Apr 2026 have thousands, so those scrapes were partial.
--   Can't be computed for the first and last snapshot, and shrinks near the
--   end of the panel because there are fewer later snapshots to come back in.
-- prev_still_present: share of the previous snapshot's listings that are in
--   this one. One-sided, so it also works for the latest snapshot.
create or replace table snapshots as
with seen as (
    select listing_id, min(snapshot_date) as first_seen, max(snapshot_date) as last_seen
    from stg_listings
    group by listing_id
),
per_snapshot as (
    select snapshot_date, count(*) as listings, count(price) as priced
    from stg_listings
    group by snapshot_date
),
holes as (
    select p.snapshot_date, count(*) as missing
    from per_snapshot p
    join seen s
      on s.first_seen < p.snapshot_date
     and s.last_seen  > p.snapshot_date
    where not exists (
        select 1 from stg_listings l
        where l.listing_id = s.listing_id
          and l.snapshot_date = p.snapshot_date
    )
    group by p.snapshot_date
),
carried as (
    select
        cur.snapshot_date,
        count(*)                                                as prev_listings,
        count(c.listing_id)                                     as still_present
    from (select snapshot_date, lag(snapshot_date) over (order by snapshot_date) as prev_date
          from per_snapshot) cur
    join stg_listings p on p.snapshot_date = cur.prev_date
    left join stg_listings c on c.snapshot_date = cur.snapshot_date and c.listing_id = p.listing_id
    group by cur.snapshot_date
)
select
    p.snapshot_date,
    row_number() over (order by p.snapshot_date)                as snapshot_no,
    p.listings,
    p.priced,
    coalesce(h.missing, 0)                                      as holes,
    round(p.listings * 1.0 / (p.listings + coalesce(h.missing, 0)), 3) as coverage,
    round(100.0 * c.still_present / c.prev_listings, 1)         as prev_still_present_pct,
    coalesce(h.missing, 0) < 0.05 * p.listings                  as is_complete
from per_snapshot p
left join holes h on h.snapshot_date = p.snapshot_date
left join carried c on c.snapshot_date = p.snapshot_date
order by p.snapshot_date;


create or replace table stg_calendar as
select
    cast(listing_id as bigint)     as listing_id,
    cast(date as date)             as cal_date,
    available = 't'                as is_available,
    try_cast(minimum_nights as int) as min_nights
from raw_calendar;


create or replace table stg_reviews as
select
    cast(listing_id as bigint)     as listing_id,
    cast(id as bigint)             as review_id,
    cast(date as date)             as review_date
from raw_reviews;


-- host_since stops being published from Dec 2025, so build one row per host
-- from whatever snapshot still had it. Name comes from the most recent snapshot.
create or replace table hosts as
select
    host_id,
    min(host_since)                                         as host_since,
    max(snapshot_date)                                      as last_seen,
    arg_max(host_name, snapshot_date)                       as host_name
from stg_listings
group by host_id;


-- the snapshot most of the analysis runs on
create or replace view latest as
select *
from stg_listings
where snapshot_date = (select max(snapshot_date) from stg_listings);
