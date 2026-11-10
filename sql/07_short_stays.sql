-- 07_short_stays.sql
-- Thailand's Hotel Act (2004) treats renting out a residential unit for less
-- than 30 days without a hotel licence as non-compliant. Two draft laws that
-- would change this were still drafts in January 2026:
-- https://www.nishimura.com/en/knowledge/publications/20260115-118456
--
-- The licence field in this dataset is empty for every Bangkok listing, so I
-- can't check who is licensed. What I can measure is how much of the supply
-- takes bookings under 30 nights. Some of that is legitimately licensed
-- (hotels, serviced apartments), so read these as exposure, not as a count of
-- illegal listings.


-- 1. Stay length mix in the latest snapshot
create or replace view stay_mix as
select
    case
        when min_nights = 1  then '1 night'
        when min_nights < 7  then '2-6 nights'
        when min_nights < 30 then '7-29 nights'
        else '30+ nights'
    end                                                             as min_stay,
    count(*)                                                        as listings,
    round(100.0 * count(*) / sum(count(*)) over (), 1)              as pct_of_listings,
    count(*) filter (where is_active)                               as active_listings,
    round(100.0 * sum(est_revenue) / sum(sum(est_revenue)) over (), 1) as pct_of_revenue
from listing_occupancy
group by 1
order by min(min_nights);


-- 2. By room type. Hotel rooms are the type most likely to hold a licence,
-- but the licence field is empty, so that can't be checked here.
create or replace view stay_by_room_type as
select
    room_type,
    count(*)                                                        as listings,
    round(100.0 * avg(case when min_nights < 30 then 1 else 0 end), 1) as pct_under_30_nights
from latest
group by room_type
order by listings desc;


-- 3. Entire homes taking stays under 30 nights, by district
create or replace view stay_by_district as
select
    district,
    count(*)                                                        as entire_homes,
    count(*) filter (where min_nights < 30)                         as under_30_nights,
    round(100.0 * avg(case when min_nights < 30 then 1 else 0 end), 1) as pct_under_30_nights
from latest
where room_type = 'Entire home/apt'
group by district
having count(*) >= 100
order by pct_under_30_nights desc;


-- 4. Over time. If enforcement or the law had moved, the monthly share should move.
create or replace view stay_trend as
select
    l.snapshot_date,
    s.is_complete,
    count(*)                                                        as listings,
    round(100.0 * avg(case when l.min_nights < 30 then 1 else 0 end), 1) as pct_under_30_nights,
    round(100.0 * avg(case when l.min_nights >= 30 then 1 else 0 end), 1) as pct_monthly_only
from stg_listings l
join snapshots s on s.snapshot_date = l.snapshot_date
where l.room_type = 'Entire home/apt'
group by l.snapshot_date, s.is_complete
order by l.snapshot_date;


-- 5. Do the big operators behave differently from one-unit owners?
create or replace view stay_by_host_tier as
select
    case
        when h.listings = 1   then '1 listing'
        when h.listings <= 4  then '2-4'
        when h.listings <= 19 then '5-19'
        when h.listings <= 99 then '20-99'
        else '100+'
    end                                                             as host_tier,
    count(*)                                                        as entire_homes,
    round(100.0 * avg(case when l.min_nights < 30 then 1 else 0 end), 1) as pct_under_30_nights
from latest l
join host_latest h on h.host_id = l.host_id
where l.room_type = 'Entire home/apt'
group by 1
order by min(h.listings);
