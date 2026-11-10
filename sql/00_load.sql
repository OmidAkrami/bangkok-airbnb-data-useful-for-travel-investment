-- 00_load.sql
-- Pull the Inside Airbnb files into DuckDB as plain text.
-- Nothing gets typed or cleaned here, that happens in 01_staging.sql.
--
-- Inside Airbnb changed the listings file 3 times inside this window
-- (75 -> 79 -> 85 -> 90 columns), so union_by_name matters: a column that
-- doesn't exist in an older file just comes through as null.
--
-- This file is DuckDB specific (read_csv). Everything after 01 is close to
-- standard SQL.

create or replace table raw_listings as
select
    regexp_extract(filename, '(\d{4}-\d{2}-\d{2})', 1) as snapshot,
    id,
    host_id,
    host_name,
    host_since,
    host_is_superhost,
    neighbourhood_cleansed,
    latitude,
    longitude,
    property_type,
    room_type,
    accommodates,
    bathrooms,
    bathrooms_text,
    bedrooms,
    amenities,
    price,
    price_quote_checkin_date,
    price_quote_checkout_date,
    minimum_nights,
    maximum_nights,
    availability_30,
    availability_90,
    availability_365,
    number_of_reviews,
    number_of_reviews_ltm,
    first_review,
    last_review,
    review_scores_rating,
    review_scores_location,
    instant_bookable,
    calculated_host_listings_count,
    estimated_occupancy_l365d,
    estimated_revenue_l365d
from read_csv(
    'data/raw/*/listings.csv.gz',
    union_by_name = true,
    filename = true,
    all_varchar = true
);

-- calendar only exists for the latest snapshot I downloaded (next 365 days)
create or replace table raw_calendar as
select listing_id, date, available, minimum_nights
from read_csv('data/raw/2026-09-22/calendar.csv.gz', all_varchar = true);

-- reviews: keeping ids and dates only. Reviewer names and comment text
-- aren't needed for anything here.
create or replace table raw_reviews as
select listing_id, id, date
from read_csv('data/raw/2026-09-22/reviews.csv.gz', all_varchar = true);
