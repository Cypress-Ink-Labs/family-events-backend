/*
  # Family Events reference data

  Production reset baseline data. This is intentionally separate from
  supabase/seed.sql, which creates a local-only auth/admin account.

  Current source decisions baked in:
  - BREC uses the dedicated `brec` parser from the start.
  - Lafayette Macaroni Kid is included with its API date window.
  - East Baton Rouge Parish Library is omitted because the old LibCal RSS feed
    was empty and the real source requires a separate LocalHop integration.
*/

-- =============================================
-- Cities
-- =============================================
INSERT INTO public.cities (name, state, country, slug, latitude, longitude, timezone)
VALUES
  ('Baton Rouge', 'LA', 'US', 'baton-rouge', 30.4515, -91.1871, 'America/Chicago'),
  ('Lafayette', 'LA', 'US', 'lafayette', 30.2241, -92.0198, 'America/Chicago')
ON CONFLICT (slug) DO UPDATE
SET
  name = EXCLUDED.name,
  state = EXCLUDED.state,
  country = EXCLUDED.country,
  latitude = EXCLUDED.latitude,
  longitude = EXCLUDED.longitude,
  timezone = EXCLUDED.timezone;

-- =============================================
-- Tags
-- =============================================
INSERT INTO public.tags (name, slug, color, category, is_system)
VALUES
  ('Free', 'free', '#16a34a', 'cost', true),
  ('Outdoor', 'outdoor', '#15803d', 'location', true),
  ('Indoor', 'indoor', '#0369a1', 'location', true),
  ('Toddler-Friendly', 'toddler-friendly', '#d97706', 'age', true),
  ('Baby-Friendly', 'baby-friendly', '#f59e0b', 'age', true),
  ('Teen-Friendly', 'teen-friendly', '#7c3aed', 'age', true),
  ('Weekend', 'weekend', '#db2777', 'time', true),
  ('Educational', 'educational', '#0284c7', 'theme', true),
  ('Arts & Crafts', 'arts-crafts', '#c026d3', 'activity', true),
  ('Music', 'music', '#ea580c', 'activity', true),
  ('Sensory-Friendly', 'sensory-friendly', '#0891b2', 'theme', true),
  ('Family Festival', 'family-festival', '#dc2626', 'theme', true),
  ('Storytime', 'storytime', '#65a30d', 'activity', true),
  ('STEM', 'stem', '#2563eb', 'theme', true),
  ('Sports', 'sports', '#16a34a', 'activity', true),
  ('Cooking', 'cooking', '#d97706', 'activity', true),
  ('Nature', 'nature', '#15803d', 'theme', true),
  ('Community', 'community', '#6d28d9', 'theme', true),
  ('Holiday', 'holiday', '#dc2626', 'theme', true),
  ('Playgroup', 'playgroup', '#0891b2', 'activity', true)
ON CONFLICT (slug) DO UPDATE
SET
  name = EXCLUDED.name,
  color = EXCLUDED.color,
  category = EXCLUDED.category,
  is_system = EXCLUDED.is_system;

-- =============================================
-- Event Sources
-- =============================================
WITH source_data AS (
  SELECT
    'BREC Parks'::text AS name,
    'https://www.brec.org/calendar'::text AS url,
    'brec'::text AS source_type,
    'baton-rouge'::text AS city_slug,
    12::integer AS scrape_interval_hours,
    NULL::integer AS date_window_days,
    'Baton Rouge parks and recreation calendar'::text AS notes
  UNION ALL SELECT
    'Eventbrite Baton Rouge Family',
    'https://www.eventbrite.com/d/la--baton-rouge/family-events/',
    'website', 'baton-rouge', 12, NULL,
    'Family-friendly Eventbrite listings for Baton Rouge'
  UNION ALL SELECT
    'AllEvents Baton Rouge Family',
    'https://allevents.in/baton-rouge/family',
    'website', 'baton-rouge', 12, NULL,
    'AllEvents family listings for Baton Rouge'
  UNION ALL SELECT
    'Moncus Park',
    'https://moncuspark.org/events/',
    'website', 'lafayette', 12, NULL,
    'Outdoor family events at Moncus Park'
  UNION ALL SELECT
    'Acadiana Center for the Arts',
    'https://acadianacenterforthearts.org/events/',
    'website', 'lafayette', 12, NULL,
    'Arts and culture events in Lafayette'
  UNION ALL SELECT
    'Lafayette Science Museum',
    'https://lafayettesciencemuseum.org/events',
    'website', 'lafayette', 12, NULL,
    'Science museum family events'
  UNION ALL SELECT
    'Lafayette Public Library',
    'https://lafayettela.libcal.com/ical_subscribe.php?src=p&cid=11334',
    'ical', 'lafayette', 6, NULL,
    'Library story times and kids programming via LibCal iCal feed'
  UNION ALL SELECT
    'Eventbrite Lafayette Family',
    'https://www.eventbrite.com/d/la--lafayette/family-events/',
    'website', 'lafayette', 12, NULL,
    'Family-friendly Eventbrite listings for Lafayette'
  UNION ALL SELECT
    'AllEvents Lafayette Family',
    'https://allevents.in/lafayette/family',
    'website', 'lafayette', 12, NULL,
    'AllEvents family listings for Lafayette'
  UNION ALL SELECT
    'Macaroni Kid Lafayette',
    'https://lafayettela.macaronikid.com/events',
    'macaronikid', 'lafayette', 12, 90,
    'JSON API; two-hop fetch (page -> townId -> api.macaronikid.com).'
)
INSERT INTO public.event_sources (
  name,
  url,
  source_type,
  city_id,
  is_active,
  scrape_interval_hours,
  date_window_days,
  notes
)
SELECT
  s.name,
  s.url,
  s.source_type,
  c.id,
  true,
  s.scrape_interval_hours,
  s.date_window_days,
  s.notes
FROM source_data s
JOIN public.cities c ON c.slug = s.city_slug
ON CONFLICT (url) DO UPDATE
SET
  name = EXCLUDED.name,
  source_type = EXCLUDED.source_type,
  city_id = EXCLUDED.city_id,
  is_active = EXCLUDED.is_active,
  scrape_interval_hours = EXCLUDED.scrape_interval_hours,
  date_window_days = EXCLUDED.date_window_days,
  notes = EXCLUDED.notes,
  updated_at = now();
