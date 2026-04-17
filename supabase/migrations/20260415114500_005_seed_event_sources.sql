/*
  # Seed real event ingestion sources

  Adds a starter set of city-specific event sources for MVP ingestion.
  Inserts are idempotent by URL.

  Sources are vetted: confirmed to return valid RSS/iCal content without
  bot-protection. Bot-protected or dead URLs are seeded as is_active=false
  so they're visible in the admin panel but won't waste scrape cycles.

  Last audited: 2026-04-16
*/

WITH seed_sources AS (
  -- ✓ CONFIRMED WORKING
  SELECT
    'BREC Family Events'::text AS name,
    'https://www.brec.org/calendar'::text AS url,
    'website'::text AS source_type,
    'baton-rouge'::text AS city_slug,
    12::integer AS scrape_interval_hours,
    true AS is_active,
    'Baton Rouge Recreation — website scraper, verified working'::text AS notes
  UNION ALL SELECT
    'Boston Public Library Events', 'https://www.bpl.org/events/feed/', 'rss', 'boston', 6, true,
    'Boston library family programming — verified RSS (application/rss+xml)'
  UNION ALL SELECT
    'Chicago Public Library Events', 'https://www.chipublib.org/events/feed/', 'rss', 'chicago', 6, true,
    'Chicago library events — verified RSS (application/rss+xml)'
  UNION ALL SELECT
    'Louisville Zoo Events', 'https://www.louisvillezoo.org/events/?ical=1&tribe_display=list', 'ical', 'louisville', 12, true,
    'Louisville Zoo family events — verified iCal (BEGIN:VCALENDAR)'

  -- ✗ BOT-PROTECTED / DEAD — seeded inactive for admin visibility
  UNION ALL SELECT
    'New York Public Library Events', 'https://www.nypl.org/events/rss', 'rss', 'new-york', 6, false,
    'BLOCKED: Imperva CDN returns HTML bot-challenge instead of RSS'
  UNION ALL SELECT
    'NYC Parks Events', 'https://www.nycgovparks.org/events', 'website', 'new-york', 12, false,
    'BLOCKED: 403 Forbidden from CDN bot protection'
  UNION ALL SELECT
    'Brooklyn Public Library Calendar', 'https://www.bklynlibrary.org/calendar/feed', 'rss', 'new-york', 6, false,
    'DEAD: 404 — feed URL no longer exists'
  UNION ALL SELECT
    'Austin Public Library Events', 'https://library.austintexas.gov/events/feed', 'rss', 'austin', 6, false,
    'DEAD: 404 — feed URL no longer exists'
  UNION ALL SELECT
    'Denver Public Library Events', 'https://www.denverlibrary.org/events/feed', 'rss', 'denver', 6, false,
    'DEAD: 404 — feed URL no longer exists'
  UNION ALL SELECT
    'Seattle Public Library Events', 'https://www.spl.org/calendar/rss', 'rss', 'seattle', 6, false,
    'BLOCKED: returns HTML, not RSS'
  UNION ALL SELECT
    'Chicago Park District Events', 'https://www.chicagoparkdistrict.com/events', 'website', 'chicago', 12, false,
    'BLOCKED: bot-protected, returns HTML challenge page'
  UNION ALL SELECT
    'Portland Parks & Rec Activities', 'https://www.portland.gov/parks/events', 'website', 'portland', 12, false,
    'BLOCKED: bot-protected website'
)
INSERT INTO public.event_sources (
  name,
  url,
  source_type,
  city_id,
  is_active,
  scrape_interval_hours,
  notes
)
SELECT
  seed.name,
  seed.url,
  seed.source_type,
  cities.id,
  seed.is_active,
  seed.scrape_interval_hours,
  seed.notes
FROM seed_sources seed
JOIN public.cities ON cities.slug = seed.city_slug
WHERE NOT EXISTS (
  SELECT 1
  FROM public.event_sources existing
  WHERE existing.url = seed.url
);
