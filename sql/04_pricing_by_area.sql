-- 04_pricing_by_area.sql
-- Prices from the latest snapshot (Sep 2026, 'quote' basis).
--
-- Two things I control for everywhere here:
--   1. stay length. The quote is for a stay of min_nights, so a 7-night
--      minimum shows a weekly per-night rate and a 30-night minimum a monthly
--      one, both discounted. First version split at 30 nights and that mixed
--      weekly lets into "short stays": they're 38% of short-stay 1-beds, cheaper
--      per night and with inflated modelled occupancy. So prices here use
--      stay_type = 'nightly' (1-6 night minimum) unless a view says otherwise.
--   2. size. A district full of 2-bedroom units isn't "more expensive" than one
--      full of studios in any useful sense. Where it matters I compare like with like.
--
-- Prices use active listings only (at least one review in the last 12 months),
-- the same base as the occupancy figures, so a district's price and occupancy
-- describe the same listings. Bad prices (price_ok = false) are excluded throughout.


-- 1. City overview by room type and stay type
create or replace view price_city_overview as
select
    room_type,
    stay_type,
    count(*)                                                        as listings,
    percentile_cont(0.25) within group (order by price)             as p25_thb,
    percentile_cont(0.50) within group (order by price)             as median_thb,
    percentile_cont(0.75) within group (order by price)             as p75_thb
from listing_occupancy
where price_ok
  and is_active
group by room_type, stay_type
having count(*) >= 50
order by room_type, min(min_nights);


-- 2. Nightly price by district: active entire homes, 1-6 night minimum.
-- premium_vs_city = how far the district median sits from the city median.
create or replace view price_by_district as
with base as (
    select l.district, l.price, l.guests, l.bedrooms
    from latest l
    join listing_occupancy o on o.listing_id = l.listing_id
    where o.price_ok
      and o.is_active
      and o.room_type = 'Entire home/apt'
      and o.stay_type = 'nightly'
),
city as (
    select percentile_cont(0.5) within group (order by price) as city_median
    from base
),
d as (
    select
        district,
        count(*)                                                    as listings,
        percentile_cont(0.25) within group (order by price)         as p25,
        percentile_cont(0.50) within group (order by price)         as median_price,
        percentile_cont(0.75) within group (order by price)         as p75,
        percentile_cont(0.50) within group (order by price / nullif(guests, 0)) as median_per_guest,
        avg(case when bedrooms >= 2 then 1.0 else 0 end)            as share_2br_plus
    from base
    group by district
)
select
    d.district,
    d.listings,
    round(d.median_price)                                           as median_thb,
    round(d.p25)                                                    as p25_thb,
    round(d.p75)                                                    as p75_thb,
    round(d.p75 - d.p25)                                            as iqr_thb,
    round(d.median_per_guest)                                       as median_per_guest_thb,
    round(100 * d.share_2br_plus, 1)                                as pct_2br_plus,
    round(100 * (d.median_price / c.city_median - 1), 1)            as premium_vs_city_pct,
    case when d.listings >= 30
         then rank() over (partition by d.listings >= 30 order by d.median_price desc)
    end                                                             as price_rank
from d
cross join city c
order by d.listings desc, d.district;


-- 3. Same thing split by size, for the districts with enough supply.
-- Conditional aggregation = a pivot without a pivot function, works anywhere.
create or replace view price_district_by_size as
select
    district,
    count(*)                                                                        as listings,
    round(percentile_cont(0.5) within group (order by price) filter (where bedrooms = 0))  as studio_thb,
    round(percentile_cont(0.5) within group (order by price) filter (where bedrooms = 1))  as one_bed_thb,
    round(percentile_cont(0.5) within group (order by price) filter (where bedrooms = 2))  as two_bed_thb,
    round(percentile_cont(0.5) within group (order by price) filter (where bedrooms >= 3)) as three_plus_thb,
    count(*) filter (where bedrooms = 1)                                            as one_bed_listings
from listing_occupancy
where price_ok
  and is_active
  and room_type = 'Entire home/apt'
  and stay_type = 'nightly'
group by district
having count(*) >= 100
order by one_bed_thb desc;


-- 4. Nightly vs monthly, 1-bedroom entire units, by district.
-- The question an owner actually asks: is Airbnb-style short letting worth it
-- over just renting the unit by the month?
--   break_even_occ = monthly per-night price / nightly price
--                    i.e. the occupancy a nightly let needs to match a unit
--                    let by the month all year
-- Ignores cleaning, platform fees, utilities and the legal side (see 07),
-- which all push the real break-even higher. It also assumes the monthly unit
-- is never empty, which is generous to monthly.
-- pct_beating_monthly is per listing, with its own price: does its estimated
-- yearly revenue beat a year of the district's median monthly rent? Comparing
-- occupancy with the district break-even instead would ignore that a listing
-- priced above the median needs fewer nights.
-- The model caps occupancy at 70%, so read this as a floor.
create or replace view price_short_vs_monthly as
with one_bed as (
    select district, stay_type, is_active, price, est_occupancy, est_revenue
    from listing_occupancy
    where price_ok
      and room_type = 'Entire home/apt'
      and bedrooms = 1
      and stay_type in ('nightly', 'monthly')
),
d as (
    select
        district,
        count(*) filter (where stay_type = 'nightly')                                       as nightly_listings,
        count(*) filter (where stay_type = 'monthly')                                       as monthly_listings,
        percentile_cont(0.5) within group (order by price) filter (where stay_type = 'nightly') as nightly_price,
        percentile_cont(0.5) within group (order by price) filter (where stay_type = 'monthly') as monthly_price
    from one_bed
    group by district
),
perf as (
    select
        o.district,
        count(*)                                                    as active_nightly,
        median(o.est_occupancy)                                     as median_occ,
        percentile_cont(0.75) within group (order by o.est_occupancy) as p75_occ,
        avg(case when o.est_revenue >= d.monthly_price * 365 then 1.0 else 0 end) as share_beating
    from one_bed o
    join d on d.district = o.district
    where o.stay_type = 'nightly' and o.is_active
    group by o.district
)
select
    d.district,
    d.nightly_listings,
    d.monthly_listings,
    round(d.nightly_price)                                          as nightly_price_thb,
    round(d.monthly_price * 30)                                     as monthly_rent_thb,
    round(100 * (1 - d.monthly_price / d.nightly_price), 1)         as monthly_discount_pct,
    round(100 * d.monthly_price / d.nightly_price, 1)               as break_even_occ_pct,
    round(100 * p.median_occ, 1)                                    as nightly_median_occ_pct,
    round(100 * p.p75_occ, 1)                                       as nightly_p75_occ_pct,
    round(100 * p.share_beating, 1)                                 as pct_beating_monthly
from d
join perf p on p.district = d.district
where d.nightly_listings >= 30 and d.monthly_listings >= 30
order by d.nightly_listings desc;


-- 5. What's an amenity worth?
-- Naive comparison (all listings with a pool vs without) mixes in location,
-- size and property type: 76% of 1-bed units have a pool (shared, in a condo
-- tower), while the expensive end of the market is houses and townhouses that
-- mostly don't. So compare inside cells instead, two ways:
--   A: same district + bedrooms
--   B: same district + bedrooms + property type
-- In each cell take median with / median without, then average the log ratios
-- weighted by the smaller group. grouping sets builds both cell levels in one
-- pass; grouping(property_type) = 1 marks the rows where it was rolled up (A).
-- The answer moves a lot with the controls. A pool in Bangkok mostly means a
-- newer condo tower, so I read this as a building premium more than a pool one.
create or replace view price_amenity_premium as
with base as (
    select l.district, l.bedrooms, l.property_type, l.price,
           l.has_pool, l.has_gym, l.has_workspace, l.has_self_checkin
    from latest l
    join listing_occupancy o on o.listing_id = l.listing_id
    where o.price_ok
      and o.room_type = 'Entire home/apt'
      and o.stay_type = 'nightly'
      and l.bedrooms between 0 and 3
),
long as (
    select district, bedrooms, property_type, price, 'pool'      as amenity, has_pool         as has_it from base
    union all
    select district, bedrooms, property_type, price, 'gym',                  has_gym                    from base
    union all
    select district, bedrooms, property_type, price, 'workspace',            has_workspace              from base
    union all
    select district, bedrooms, property_type, price, 'self check-in',        has_self_checkin           from base
),
naive as (
    select
        amenity,
        round(100.0 * avg(case when has_it then 1 else 0 end), 1)  as pct_of_listings,
        percentile_cont(0.5) within group (order by price) filter (where has_it)
          / percentile_cont(0.5) within group (order by price) filter (where not has_it) as naive_ratio
    from long
    group by amenity
),
cells as (
    select
        amenity,
        case when grouping(property_type) = 1 then 'A' else 'B' end as level,
        count(*) filter (where has_it)                              as n_with,
        count(*) filter (where not has_it)                          as n_without,
        percentile_cont(0.5) within group (order by price) filter (where has_it)     as med_with,
        percentile_cont(0.5) within group (order by price) filter (where not has_it) as med_without
    from long
    group by grouping sets ((amenity, district, bedrooms), (amenity, district, bedrooms, property_type))
    having count(*) filter (where has_it) >= 10
       and count(*) filter (where not has_it) >= 10
),
controlled as (
    select
        amenity,
        level,
        count(*)                                                    as cells_used,
        exp(sum(least(n_with, n_without) * ln(med_with / med_without))
            / sum(least(n_with, n_without)))                        as ratio
    from cells
    group by amenity, level
)
select
    n.amenity,
    n.pct_of_listings,
    round(100 * (n.naive_ratio - 1), 1)                             as naive_premium_pct,
    round(100 * (max(c.ratio) filter (where c.level = 'A') - 1), 1) as premium_same_district_size_pct,
    round(100 * (max(c.ratio) filter (where c.level = 'B') - 1), 1) as premium_plus_property_type_pct,
    max(c.cells_used) filter (where c.level = 'B')                  as cells_used_b
from naive n
join controlled c on c.amenity = n.amenity
group by n.amenity, n.pct_of_listings, n.naive_ratio
order by premium_plus_property_type_pct desc;


-- 6. Price bands vs guest rating and occupancy (entire homes, nightly, active).
create or replace view price_bands_vs_performance as
with base as (
    select
        price, rating, est_occupancy, est_revenue,
        ntile(10) over (order by price)                             as price_decile
    from listing_occupancy
    where price_ok and is_active
      and room_type = 'Entire home/apt'
      and stay_type = 'nightly'
)
select
    price_decile,
    count(*)                                                        as listings,
    round(min(price))                                               as from_thb,
    round(max(price))                                               as to_thb,
    round(median(rating), 2)                                        as median_rating,
    round(100 * median(est_occupancy), 1)                           as median_occ_pct,
    round(median(est_revenue))                                      as median_revenue_thb
from base
group by price_decile
order by price_decile;


-- 7. District positioning: price vs occupancy against the city medians.
-- Feeds the scatter on the dashboard. Entire homes, nightly, active.
create or replace view price_district_quadrants as
with base as (
    select district, price, est_occupancy
    from listing_occupancy
    where price_ok and is_active
      and room_type = 'Entire home/apt'
      and stay_type = 'nightly'
),
d as (
    select
        district,
        count(*)                                                    as active_listings,
        percentile_cont(0.5) within group (order by price)          as median_price,
        percentile_cont(0.5) within group (order by est_occupancy)  as median_occ
    from base
    group by district
    having count(*) >= 30
),
city as (
    select
        percentile_cont(0.5) within group (order by price)          as city_price,
        percentile_cont(0.5) within group (order by est_occupancy)  as city_occ
    from base
)
select
    d.district,
    d.active_listings,
    round(d.median_price)                                           as median_price_thb,
    round(100 * (d.median_price / c.city_price - 1), 1)             as price_vs_city_pct,
    round(100 * d.median_occ, 1)                                    as median_occ_pct,
    case
        when d.median_price >= c.city_price and d.median_occ >= c.city_occ then 'high price, high occupancy'
        when d.median_price >= c.city_price                              then 'high price, low occupancy'
        when d.median_occ   >= c.city_occ                                then 'low price, high occupancy'
        else 'low price, low occupancy'
    end                                                             as quadrant
from d
cross join city c
order by d.active_listings desc, d.district;
