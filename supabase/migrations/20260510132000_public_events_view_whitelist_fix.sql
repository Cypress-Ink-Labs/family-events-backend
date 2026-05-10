/*
  # Decision 1B follow-up: align public_events whitelist with approved design

  The public view must expose only these published-event columns:
  id, title, description, start_datetime, end_datetime, timezone, venue_name,
  address, city_id, latitude, longitude, age_min, age_max, price, is_free,
  source_url, source_name, images, recurrence_info, is_featured.
*/

drop view if exists public.public_events;

create view public.public_events as
select
  e.id,
  e.title,
  e.description,
  e.start_datetime,
  e.end_datetime,
  e.timezone,
  e.venue_name,
  e.address,
  e.city_id,
  e.latitude,
  e.longitude,
  e.age_min,
  e.age_max,
  e.price,
  e.is_free,
  e.source_url,
  e.source_name,
  e.images,
  e.recurrence_info,
  e.is_featured
from public.events e
where e.status = 'published';

grant select on public.public_events to anon;
