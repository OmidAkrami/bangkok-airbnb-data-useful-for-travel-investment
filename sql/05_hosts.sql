-- 05_hosts.sql
-- Who actually runs Bangkok's Airbnb supply.
-- Listing counts per host are computed here from the snapshot itself rather
-- than trusting calculated_host_listings_count, so every number lines up.
-- Host names are only shown for hosts with 20+ listings. At that size it's a
-- business. Below it, it's often someone renting out their own flat.
-- Everything here is per host account. Some companies run several accounts
-- (see host_handovers), so true operator concentration is a bit higher.


create or replace table host_latest as
select
    l.host_id,
    count(*)                                                        as listings,
    count(*) filter (where o.is_active)                             as active_listings,
    count(distinct l.district)                                      as districts,
    avg(case when l.room_type = 'Entire home/apt' then 1.0 else 0 end) as share_entire,
    bool_or(l.is_superhost)                                         as is_superhost,
    median(l.price) filter (where l.price_ok)                       as median_price,
    median(l.rating)                                                as median_rating,
    median(o.est_occupancy) filter (where o.is_active)              as median_occ,
    coalesce(sum(o.est_revenue), 0)                                 as est_revenue
from latest l
join listing_occupancy o on o.listing_id = l.listing_id
group by l.host_id;


-- 1. Host size tiers (by total listings on the account).
-- Medians are over listings, not over hosts. A first version took the median
-- of each host's median, which made the 100+ tier look far worse (8%) than its
-- typical active listing actually is (16%).
create or replace view host_tiers as
with t as (
    select
        o.*,
        h.listings                                                  as host_size,
        case
            when h.listings = 1   then '1 listing'
            when h.listings <= 4  then '2-4'
            when h.listings <= 19 then '5-19'
            when h.listings <= 99 then '20-99'
            else '100+'
        end                                                         as tier
    from listing_occupancy o
    join host_latest h on h.host_id = o.host_id
)
select
    tier,
    count(distinct host_id)                                         as hosts,
    count(*)                                                        as listings,
    count(*) filter (where is_active)                               as active_listings,
    round(100.0 * count(*) filter (where is_active) / count(*), 1)  as pct_active,
    round(100.0 * count(*) / sum(count(*)) over (), 1)              as pct_of_listings,
    round(100.0 * count(*) filter (where is_active)
          / sum(count(*) filter (where is_active)) over (), 1)      as pct_of_active_listings,
    round(100.0 * sum(est_revenue) / sum(sum(est_revenue)) over (), 1) as pct_of_revenue,
    round(100 * median(est_occupancy) filter (where is_active), 1)  as median_occ_active_pct,
    round(median(rating), 2)                                        as median_rating,
    round(100.0 * avg(case when is_superhost then 1 else 0 end), 1) as pct_superhost_listings
from t
group by tier
order by min(host_size);


-- 2. Top 15 hosts by listing count, with their main district
create or replace view host_top as
with district_counts as (
    select
        host_id,
        district,
        count(*)                                                    as n,
        row_number() over (partition by host_id order by count(*) desc, district) as rn
    from latest
    group by host_id, district
),
ranked as (
    select
        h.*,
        rank() over (order by h.listings desc)                      as listings_rank,
        rank() over (order by h.est_revenue desc)                   as revenue_rank
    from host_latest h
)
select
    r.listings_rank,
    r.host_id,
    case when r.listings >= 20 then hs.host_name end                as host_name,
    r.listings,
    r.active_listings,
    r.districts,
    dc.district                                                     as main_district,
    round(100 * r.share_entire, 1)                                  as pct_entire_home,
    round(r.median_price)                                           as median_price_thb,
    round(r.median_rating, 2)                                       as median_rating,
    round(100 * r.median_occ, 1)                                    as median_occ_pct,
    round(r.est_revenue / 1e6, 1)                                   as est_revenue_m_thb,
    r.revenue_rank
from ranked r
join hosts hs on hs.host_id = r.host_id
join district_counts dc on dc.host_id = r.host_id and dc.rn = 1
where r.listings_rank <= 15
order by r.listings_rank, r.host_id;


-- 3. Concentration: how much of the market sits with the biggest hosts.
-- Gini on listings per host: 0 = everyone has the same number, 1 = one host has everything.
-- Formula with hosts sorted ascending: G = 2*sum(i*x_i) / (n*sum(x_i)) - (n+1)/n
create or replace view host_concentration as
with ranked as (
    select
        listings,
        est_revenue,
        row_number() over (order by listings desc)                  as rank_desc,
        row_number() over (order by listings asc)                   as rank_asc,
        row_number() over (order by est_revenue desc)               as revenue_rank_desc,
        count(*) over ()                                            as n_hosts
    from host_latest
)
select
    max(n_hosts)                                                    as hosts,
    sum(listings)                                                   as listings,
    round(100.0 * sum(listings) filter (where rank_desc <= 0.01 * n_hosts) / sum(listings), 1) as top_1pct_hosts_share,
    round(100.0 * sum(listings) filter (where rank_desc <= 0.10 * n_hosts) / sum(listings), 1) as top_10pct_hosts_share,
    -- revenue held by the same top 1% (by listings), then the top 1% ranked by revenue
    round(100.0 * sum(est_revenue) filter (where rank_desc <= 0.01 * n_hosts) / sum(est_revenue), 1) as top_1pct_by_listings_revenue_share,
    round(100.0 * sum(est_revenue) filter (where revenue_rank_desc <= 0.01 * n_hosts) / sum(est_revenue), 1) as top_1pct_by_revenue_revenue_share,
    round(100.0 * sum(listings) filter (where rank_desc <= 15) / sum(listings), 1) as top_15_hosts_share,
    round(2.0 * sum(rank_asc * listings) / (max(n_hosts) * sum(listings))
          - (max(n_hosts) + 1.0) / max(n_hosts), 3)                 as gini_listings
from ranked;


-- 4. Concentration by district: HHI = sum of squared market shares (in %).
-- Thresholds from the 1992 US merger guidelines, used loosely:
-- under 1000 unconcentrated, 1000-1800 moderate, over 1800 high (1800 is still
-- the "highly concentrated" line in the 2023 guidelines).
-- Active listings only, so a host parking 100 dead listings doesn't count as
-- market share. Districts with at least 50 active listings.
create or replace view host_district_hhi as
with shares as (
    select
        district,
        host_id,
        count(*)                                                    as listings,
        100.0 * count(*) / sum(count(*)) over (partition by district) as share_pct,
        row_number() over (partition by district order by count(*) desc) as rn
    from latest
    where reviews_ltm > 0
    group by district, host_id
)
select
    s.district,
    sum(s.listings)                                                 as active_listings,
    count(*)                                                        as hosts,
    round(sum(s.share_pct * s.share_pct))                           as hhi,
    case
        when sum(s.share_pct * s.share_pct) > 1800 then 'high'
        when sum(s.share_pct * s.share_pct) >= 1000 then 'moderate'
        else 'unconcentrated'
    end                                                             as concentration,
    round(max(s.share_pct), 1)                                      as top_host_share_pct,
    round(sum(s.share_pct) filter (where s.rn <= 5), 1)             as top5_hosts_share_pct
from shares s
group by s.district
having sum(s.listings) >= 50
order by hhi desc, s.district;


-- 5. Is the market professionalising? Share of active listings run by hosts
-- with 10+ active listings, per snapshot. Partial snapshots kept but flagged.
-- Active only, on purpose. My first version counted all listings and showed a
-- jump from 46% to 51% between Jan and Jun 2026. About half of that was the
-- scraper dropping dormant listings from Feb 2026 (see dq_dormant_listings),
-- which skew towards single-unit hosts. On active listings the share sits at
-- 41-43% for 16 months and then steps up to 44.5% across the Feb-May gap.
-- A one-off step inside a gap with partial scrapes: I can't tell from this data
-- whether it's real or another scrape change, so I don't call it a trend.
create or replace view host_pro_share_trend as
with per_host as (
    select snapshot_date, host_id, count(*) as listings
    from stg_listings
    where reviews_ltm > 0
    group by snapshot_date, host_id
)
select
    p.snapshot_date,
    s.is_complete,
    count(*)                                                        as active_hosts,
    sum(p.listings)                                                 as active_listings,
    round(sum(p.listings) * 1.0 / count(*), 2)                      as listings_per_host,
    round(100.0 * sum(p.listings) filter (where p.listings >= 10) / sum(p.listings), 1) as pct_listings_10plus_hosts,
    round(100.0 * count(*) filter (where p.listings = 1) / count(*), 1) as pct_single_listing_hosts
from per_host p
join snapshots s on s.snapshot_date = p.snapshot_date
group by p.snapshot_date, s.is_complete
order by p.snapshot_date;


-- 6. Biggest movers between Sep 2025 and Sep 2026 (both full snapshots),
-- counting active listings. full outer join so hosts that appeared or
-- vanished are counted too.
create or replace view host_movers as
with a as (
    select host_id, count(*) as n from stg_listings
    where snapshot_date = date '2025-09-26' and reviews_ltm > 0 group by host_id
),
b as (
    select host_id, count(*) as n from stg_listings
    where snapshot_date = date '2026-09-22' and reviews_ltm > 0 group by host_id
),
j as (
    select
        coalesce(a.host_id, b.host_id)                              as host_id,
        coalesce(a.n, 0)                                            as sep_2025,
        coalesce(b.n, 0)                                            as sep_2026
    from a
    full outer join b on a.host_id = b.host_id
)
select
    j.host_id,
    case when greatest(j.sep_2025, j.sep_2026) >= 20 then h.host_name end as host_name,
    j.sep_2025,
    j.sep_2026,
    j.sep_2026 - j.sep_2025                                         as change
from j
join hosts h on h.host_id = j.host_id
where abs(j.sep_2026 - j.sep_2025) >= 25
order by change desc;


-- hosts with at least one active listing, a year apart
create or replace view host_entry_exit as
with a as (
    select distinct host_id from stg_listings
    where snapshot_date = date '2025-09-26' and reviews_ltm > 0
),
b as (
    select distinct host_id from stg_listings
    where snapshot_date = date '2026-09-22' and reviews_ltm > 0
)
select
    (select count(*) from a)                                        as hosts_sep_2025,
    (select count(*) from b)                                        as hosts_sep_2026,
    (select count(*) from a where host_id not in (select host_id from b)) as hosts_gone,
    (select count(*) from b where host_id not in (select host_id from a)) as hosts_new;


-- 7. Listings that switch host between snapshots. Mostly management companies
-- taking over units (or one company moving units between its own accounts).
create or replace view host_handovers as
with h as (
    select
        listing_id,
        snapshot_date,
        host_id,
        lag(host_id) over (partition by listing_id order by snapshot_date) as prev_host_id
    from stg_listings
)
select
    h.host_id                                                       as new_host_id,
    case when count(*) >= 20 then hs.host_name end                  as new_host_name,
    count(*)                                                        as listings_taken_over,
    count(distinct h.prev_host_id)                                  as from_hosts,
    min(h.snapshot_date)                                            as first_seen,
    max(h.snapshot_date)                                            as last_seen
from h
join hosts hs on hs.host_id = h.host_id
where h.prev_host_id is not null
  and h.prev_host_id <> h.host_id
group by h.host_id, hs.host_name
having count(*) >= 15
order by listings_taken_over desc, new_host_id;


-- 8. Superhost effect, compared inside district + room type cells so location
-- doesn't do the work. Weighted by the smaller group in each cell.
create or replace view host_superhost_effect as
with cells as (
    select
        district,
        room_type,
        count(*) filter (where is_superhost)                        as n_super,
        count(*) filter (where not is_superhost)                    as n_other,
        median(price) filter (where is_superhost and price_ok)      as price_super,
        median(price) filter (where not is_superhost and price_ok)  as price_other,
        median(est_occupancy) filter (where is_superhost)           as occ_super,
        median(est_occupancy) filter (where not is_superhost)       as occ_other,
        median(rating) filter (where is_superhost)                  as rating_super,
        median(rating) filter (where not is_superhost)              as rating_other
    from listing_occupancy
    where is_active
    group by district, room_type
    having count(*) filter (where is_superhost) >= 15
       and count(*) filter (where not is_superhost) >= 15
)
select
    count(*)                                                        as cells,
    sum(n_super)                                                    as superhost_listings,
    sum(n_other)                                                    as other_listings,
    round(100 * (exp(sum(least(n_super, n_other) * ln(price_super / price_other))
                     / sum(least(n_super, n_other))) - 1), 1)       as price_premium_pct,
    round(100 * sum(least(n_super, n_other) * (occ_super - occ_other))
          / sum(least(n_super, n_other)), 1)                        as occupancy_gap_pts,
    round(sum(least(n_super, n_other) * (rating_super - rating_other))
          / sum(least(n_super, n_other)), 2)                        as rating_gap
from cells;
