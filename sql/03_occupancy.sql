-- 03_occupancy.sql
-- Airbnb doesn't publish bookings, so occupancy has to be estimated.
--
-- Method: Inside Airbnb's "San Francisco model".
--   bookings in last 12m  = reviews in last 12m / 0.5   (assume half of guests leave a review)
--   nights per booking    = 3, or min_nights if that's higher
--   nights booked         = bookings * nights per booking, capped at 255 (70% of the year)
--
-- I rebuilt it from scratch first and then checked it against the
-- estimated_occupancy_l365d column Inside Airbnb started publishing in 2025.
-- They match exactly (occ_model_check), so the logic below is the real thing.
--
-- It's a rough model. The 50% review rate is a guess, and the calendar can't
-- tell a booked night from a night the host blocked. Treat it as a ranking
-- tool (which areas / listings do better) more than an absolute number.
--
-- est_revenue is null when there's no usable price: 678 active listings (4%)
-- in Sep 2026. Revenue totals and shares leave them out.
--
-- stay_type matters a lot later. The model multiplies reviews by min_nights,
-- and from 2026 the price is a quote for a min_nights stay, so a 7-night
-- minimum listing shows a weekly per-night rate AND gets more modelled nights
-- per review. Pricing in 04 uses 'nightly' (1-6 night minimum) when it means
-- short stays.


create or replace table listing_occupancy as
select
    listing_id,
    host_id,
    district,
    room_type,
    bedrooms,
    min_nights,
    price,
    price_ok,
    rating,
    is_superhost,
    reviews_ltm,
    reviews_ltm > 0                                               as is_active,
    min_nights < 30                                               as takes_short_stays,
    case
        when min_nights <= 6  then 'nightly'
        when min_nights <= 29 then 'weekly'
        else 'monthly'
    end                                                           as stay_type,
    least(reviews_ltm * 2 * greatest(min_nights, 3), 255)         as est_nights,
    iab_occ_nights,
    round(least(reviews_ltm * 2 * greatest(min_nights, 3), 255) / 365.0, 3) as est_occupancy,
    case when price_ok
         then least(reviews_ltm * 2 * greatest(min_nights, 3), 255) * price
    end                                                           as est_revenue
from latest;


-- 1. Does my version reproduce theirs?
create or replace view occ_model_check as
select
    count(*)                                                    as listings,
    count(*) filter (where est_nights = iab_occ_nights)         as exact_match,
    round(100.0 * count(*) filter (where est_nights = iab_occ_nights) / count(*), 2) as pct_match,
    round(corr(est_nights, iab_occ_nights), 4)                  as correlation
from listing_occupancy;


-- 2. Headline numbers for active listings (at least one review in the last 12 months),
-- by room type plus a city total row. grouping sets does both in one pass.
create or replace view occ_summary as
select
    coalesce(room_type, 'All active listings')                  as room_type,
    count(*)                                                    as active_listings,
    round(median(est_occupancy) * 100, 1)                       as median_occ_pct,
    round(avg(est_occupancy) * 100, 1)                          as avg_occ_pct,
    round(100.0 * count(*) filter (where est_occupancy >= 0.5) / count(*), 1) as pct_above_50,
    round(median(est_revenue))                                  as median_revenue_thb,
    round(sum(est_revenue) / 1e6, 1)                            as total_revenue_m_thb
from listing_occupancy
where is_active
group by grouping sets ((room_type), ())
order by active_listings desc;


-- 3. Distribution. Most active listings are barely booked, a small group is near the cap.
create or replace view occ_distribution as
select
    case
        when est_nights >= 255    then '70% (capped)'
        when est_occupancy < 0.05 then '0-5%'
        when est_occupancy < 0.10 then '5-10%'
        when est_occupancy < 0.20 then '10-20%'
        when est_occupancy < 0.30 then '20-30%'
        when est_occupancy < 0.50 then '30-50%'
        else '50-70%'
    end                                                         as occupancy_band,
    count(*)                                                    as listings,
    round(100.0 * count(*) / sum(count(*)) over (), 1)          as pct_of_active,
    round(sum(est_revenue) / 1e6, 1)                            as revenue_m_thb,
    round(100.0 * sum(est_revenue) / sum(sum(est_revenue)) over (), 1) as pct_of_revenue
from listing_occupancy
where is_active
group by 1
order by min(est_occupancy);


-- 4. By district. Districts with fewer than 30 active listings are kept but not ranked.
create or replace view occ_by_district as
with d as (
    select
        district,
        count(*)                                                as active_listings,
        median(est_occupancy)                                   as median_occ,
        percentile_cont(0.75) within group (order by est_occupancy) as p75_occ,
        avg(case when est_occupancy >= 0.5 then 1.0 else 0 end) as share_above_50,
        median(est_revenue)                                     as median_revenue,
        sum(est_revenue)                                        as total_revenue
    from listing_occupancy
    where is_active
    group by district
)
select
    district,
    active_listings,
    round(median_occ * 100, 1)                                  as median_occ_pct,
    round(p75_occ * 100, 1)                                     as p75_occ_pct,
    round(share_above_50 * 100, 1)                              as pct_above_50,
    round(median_revenue)                                       as median_revenue_thb,
    round(total_revenue / 1e6, 1)                               as total_revenue_m_thb,
    round(100.0 * total_revenue / sum(total_revenue) over (), 1) as pct_of_city_revenue,
    case when active_listings >= 30
         then rank() over (partition by active_listings >= 30 order by median_revenue desc)
    end                                                         as revenue_rank
from d
order by total_revenue desc;


-- 5. How concentrated is the money? Listings split into 10 equal groups by revenue.
create or replace view occ_revenue_deciles as
with ranked as (
    select est_revenue, ntile(10) over (order by est_revenue desc) as decile
    from listing_occupancy
    where is_active and est_revenue is not null
)
select
    decile,
    count(*)                                                    as listings,
    round(min(est_revenue))                                     as min_revenue_thb,
    round(max(est_revenue))                                     as max_revenue_thb,
    round(100.0 * sum(est_revenue) / sum(sum(est_revenue)) over (), 1) as pct_of_revenue,
    round(100.0 * sum(sum(est_revenue)) over (order by decile)
          / sum(sum(est_revenue)) over (), 1)                   as cumulative_pct
from ranked
group by decile
order by decile;


-- 6. Forward view from the calendar: what share of nights are already
-- unavailable for each month ahead? Unavailable = booked OR blocked, so this is
-- an upper bound. Only listings that are live: reviewed in the last year and not
-- blocked for the entire next 365 days.
-- Read only the first 4-5 months. After that the number climbs again, and that's
-- not demand: lots of hosts only open their calendar 3 to 6 months out, so far
-- dates show as unavailable by default.
create or replace view occ_calendar_ahead as
with live as (
    select c.listing_id
    from stg_calendar c
    join listing_occupancy o on o.listing_id = c.listing_id
    where o.is_active
    group by c.listing_id
    having bool_or(c.is_available)
)
select
    date_trunc('month', c.cal_date)                             as month,
    count(distinct c.listing_id)                                as listings,
    round(100.0 * avg(case when c.is_available then 0 else 1 end), 1) as pct_nights_unavailable
from stg_calendar c
join live l on l.listing_id = c.listing_id
where c.cal_date >= date '2026-10-01'
  and c.cal_date <  date '2027-09-01'
group by 1
order by 1;


-- 7. Same forward view for the high season (Nov 2026 to Feb 2027) by district,
-- next to the review-based estimate. If both point the same way I trust the ranking more.
create or replace view occ_high_season_by_district as
with live as (
    select c.listing_id
    from stg_calendar c
    join listing_occupancy o on o.listing_id = c.listing_id
    where o.is_active
    group by c.listing_id
    having bool_or(c.is_available)
),
ahead as (
    select
        o.district,
        count(distinct c.listing_id)                            as live_listings,
        avg(case when c.is_available then 0 else 1 end)        as share_unavailable
    from stg_calendar c
    join live l on l.listing_id = c.listing_id
    join listing_occupancy o on o.listing_id = c.listing_id
    where c.cal_date between date '2026-11-01' and date '2027-02-28'
    group by o.district
)
select
    a.district,
    a.live_listings,
    round(a.share_unavailable * 100, 1)                         as pct_unavailable_nov_feb,
    d.median_occ_pct                                            as review_model_median_occ_pct,
    rank() over (order by a.share_unavailable desc)             as calendar_rank
from ahead a
join occ_by_district d on d.district = a.district
where a.live_listings >= 30
order by a.share_unavailable desc;


-- 8. One number for "do the two methods agree": Spearman rank correlation
-- (correlation of the ranks) across districts. Several districts tie on the
-- model median (it moves in steps of 1 review), so ties get the average of
-- the ranks they span: rank + (ties - 1) / 2.
create or replace view occ_method_agreement as
with r as (
    select
        rank() over (order by pct_unavailable_nov_feb desc)
          + (count(*) over (partition by pct_unavailable_nov_feb) - 1) / 2.0     as calendar_rank,
        rank() over (order by review_model_median_occ_pct desc)
          + (count(*) over (partition by review_model_median_occ_pct) - 1) / 2.0 as model_rank
    from occ_high_season_by_district
)
select
    count(*)                                                    as districts,
    round(corr(calendar_rank, model_rank), 2)                   as spearman_rho
from r;
