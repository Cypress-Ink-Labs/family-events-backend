/*
  # Seed real event ingestion sources

  Adds a starter set of city-specific event sources for MVP ingestion.
  Inserts are idempotent by URL.
*/

WITH seed_sources AS (
  SELECT
    'New York Public Library Events RSS'::text AS name,
    'https://www.nypl.org/events/rss'::text AS url,
    'rss'::text AS source_type,
    'new-york'::text AS city_slug,
    6::integer AS scrape_interval_hours,
    'Library family programming feed'::text AS notes
  UNION ALL SELECT
    'Brooklyn Public Library Calendar', 'https://www.bklynlibrary.org/calendar/feed', 'rss', 'new-york', 6, 'Brooklyn branch events'
  UNION ALL SELECT
    'NYC Parks Events', 'https://www.nycgovparks.org/events', 'website', 'new-york', 12, 'City parks programming'
  UNION ALL SELECT
    'Chicago Public Library Events', 'https://www.chipublib.org/events/feed/', 'rss', 'chicago', 6, 'Chicago library events'
  UNION ALL SELECT
    'Chicago Park District Events', 'https://www.chicagoparkdistrict.com/events', 'website', 'chicago', 12, 'Park district events'
  UNION ALL SELECT
    'Austin Public Library Events', 'https://library.austintexas.gov/events/feed', 'rss', 'austin', 6, 'Austin library programs'
  UNION ALL SELECT
    'Boston Public Library Events', 'https://www.bpl.org/events/feed/', 'rss', 'boston', 6, 'Boston family events'
  UNION ALL SELECT
    'Seattle Public Library Events', 'https://www.spl.org/calendar/rss', 'rss', 'seattle', 6, 'Seattle library calendar'
  UNION ALL SELECT
    'Denver Public Library Events', 'https://www.denverlibrary.org/events/feed', 'rss', 'denver', 6, 'Denver branch events'
  UNION ALL SELECT
    'Portland Parks & Rec Activities', 'https://www.portland.gov/parks/events', 'website', 'portland', 12, 'Parks and recreation listings'
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
  true,
  seed.scrape_interval_hours,
  seed.notes
FROM seed_sources seed
JOIN public.cities ON cities.slug = seed.city_slug
WHERE NOT EXISTS (
  SELECT 1
  FROM public.event_sources existing
  WHERE existing.url = seed.url
);
