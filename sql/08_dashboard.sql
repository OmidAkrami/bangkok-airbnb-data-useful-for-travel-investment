-- 08_dashboard.sql
-- Flat tables for the dashboard. build.py writes every dash_ view to dashboard/<name>.csv,
-- and scripts/make_dashboard_data.py bundles them for docs/index.html.
-- They load into Tableau or Power BI as they are: join districts.csv to
-- bangkok_districts.geojson on district = neighbourhood.


-- headline tiles, one row
create or replace view dash_kpis as
select
    (select count(*) from latest)                                                   as listings,
    (select count(*) from listing_occupancy where is_active)                        as active_listings,
    (select count(distinct host_id) from latest)                                    as hosts,
    (select median_thb from price_city_overview
      where room_type = 'Entire home/apt' and stay_type = 'nightly')                as median_nightly_entire_thb,
    -- occupancy on the same base as the nightly price: active entire homes, 1-6 night minimum
    (select round(100 * median(est_occupancy), 1) from listing_occupancy
      where is_active and price_ok and room_type = 'Entire home/apt' and stay_type = 'nightly') as median_occ_pct,
    (select median_occ_pct from occ_summary where room_type = 'All active listings') as median_occ_all_active_pct,
    (select total_revenue_m_thb from occ_summary where room_type = 'All active listings') as est_revenue_m_thb,
    (select yoy_pct from trend_demand_ltm where snapshot_date = date '2026-09-22')   as demand_yoy_pct,
    -- active listings, not all listings (see dq_dormant_listings)
    (select round(100.0 * (b.n - a.n) / a.n, 1)
       from (select count(*) n from stg_listings where snapshot_date = date '2025-09-26' and reviews_ltm > 0) a,
            (select count(*) n from stg_listings where snapshot_date = date '2026-09-22' and reviews_ltm > 0) b) as active_supply_yoy_pct,
    -- share of active listings whose host has 10+ active listings
    (select pct_listings_10plus_hosts from host_pro_share_trend
      where snapshot_date = date '2026-09-22')                                      as pct_active_listings_pro_hosts;


-- one row per district, everything the map and the table need
create or replace view dash_districts as
with base as (
    select
        district,
        count(*)                                                    as listings,
        avg(lat)                                                    as lat,
        avg(lon)                                                    as lon
    from latest
    group by district
),
pro as (
    -- same definition as the KPI tile: active listings whose host has 10+ active listings
    select l.district,
           avg(case when h.active_listings >= 10 then 1.0 else 0 end) as share_pro
    from latest l
    join host_latest h on h.host_id = l.host_id
    where l.reviews_ltm > 0
    group by l.district
)
-- careful with labels: nightly_* columns are entire homes, 1-6 night minimum,
-- active only (same base as price_district_quadrants, and the premium is
-- against that base's city median).
-- median_occ_all_active_pct includes private rooms and hostels, so it's lower in
-- backpacker areas like Phra Nakhon.
select
    b.district,
    b.listings,
    o.active_listings,
    q.median_price_thb                                              as nightly_price_thb,
    q.price_vs_city_pct                                             as nightly_price_vs_city_pct,
    q.median_occ_pct                                                as nightly_occ_pct,
    o.median_occ_pct                                                as median_occ_all_active_pct,
    o.median_revenue_thb,
    o.total_revenue_m_thb,
    o.pct_of_city_revenue,
    s.pct_under_30_nights,
    round(100 * pr.share_pro, 1)                                    as pct_active_listings_pro_hosts,
    g.active_change_pct                                             as active_listings_yoy_pct,
    hh.hhi,
    q.quadrant,
    round(b.lat, 5)                                                 as lat,
    round(b.lon, 5)                                                 as lon
from base b
left join occ_by_district o     on o.district = b.district
left join stay_by_district s    on s.district = b.district
left join pro pr                on pr.district = b.district
left join trend_district_growth g on g.district = b.district
left join host_district_hhi hh  on hh.district = b.district
left join price_district_quadrants q on q.district = b.district
order by b.listings desc, b.district;


-- one row per snapshot for the trend lines
create or replace view dash_monthly as
select
    s.snapshot_date,
    s.is_complete,
    s.listings,
    s.active_listings,
    s.new_listings,
    s.gone_listings,
    d.reviews_last_12m,
    pl.price_index                                                  as price_index_listed,
    pq.price_index                                                  as price_index_quote,
    h.pct_listings_10plus_hosts
from trend_supply s
left join trend_demand_ltm d       on d.snapshot_date = s.snapshot_date
left join trend_price_index pl     on pl.snapshot_date = s.snapshot_date and pl.price_basis = 'listed'
left join trend_price_index pq     on pq.snapshot_date = s.snapshot_date and pq.price_basis = 'quote'
left join host_pro_share_trend h   on h.snapshot_date = s.snapshot_date
order by s.snapshot_date;


create or replace view dash_reviews_monthly as
select month, reviews, rolling_3m, yoy_pct
from trend_reviews_monthly
where month >= date '2019-01-01';


create or replace view dash_host_tiers as
select * from host_tiers;


-- listing level, latest snapshot, for the scatter and point map
create or replace view dash_listings as
select
    o.listing_id,
    o.district,
    l.lat,
    l.lon,
    o.room_type,
    o.bedrooms,
    case when o.price_ok then o.price end                           as price_thb,
    o.min_nights,
    o.takes_short_stays,
    o.is_active,
    round(100 * o.est_occupancy, 1)                                 as est_occ_pct,
    round(o.est_revenue)                                            as est_revenue_thb,
    o.rating,
    o.is_superhost,
    case
        when h.listings = 1   then '1 listing'
        when h.listings <= 4  then '2-4'
        when h.listings <= 19 then '5-19'
        when h.listings <= 99 then '20-99'
        else '100+'
    end                                                             as host_tier
from listing_occupancy o
join latest l      on l.listing_id = o.listing_id
join host_latest h on h.host_id = o.host_id;
