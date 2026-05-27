-- =============================================
-- Tier 3 Lafayette sources — Downtown Lafayette (DDA) and LCG Parks calendar
-- Also extends the source_type check constraint to allow the two new parser types.
--
-- Parsers added (edge function):
--   downtownlafayette  — Webflow CMS, static w-dyn-item card parsing
--   lcglafayette       — Vision CMS, gs-feed-list-item parsing; datetime from URL slug
-- =============================================

-- Extend source_type check constraint
ALTER TABLE public.event_sources
  DROP CONSTRAINT IF EXISTS "event_sources_source_type_check";

ALTER TABLE public.event_sources
  ADD CONSTRAINT "event_sources_source_type_check"
  CHECK (source_type = ANY (ARRAY[
    'website'::text,
    'ical'::text,
    'rss'::text,
    'manual'::text,
    'macaronikid'::text,
    'brec'::text,
    'downtownlafayette'::text,
    'lcglafayette'::text
  ]));

-- Insert new sources
INSERT INTO public.event_sources (
  name,
  url,
  source_type,
  city_id,
  is_active,
  auto_approve,
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
  false,
  s.scrape_interval_hours,
  s.date_window_days,
  s.notes
FROM (VALUES
  (
    'Downtown Lafayette (DDA)',
    'https://www.downtownlafayette.org/events',
    'downtownlafayette',
    12,
    NULL::integer,
    'Downtown Development Authority events page. Webflow CMS with Finsweet filter; events in static HTML. Live music, arts festivals, Bach Lunch, ArtWalk, cultural events.'
  ),
  (
    'Lafayette Consolidated Government Events',
    'https://www.lafayettela.gov/your-government/events-calendar/',
    'lcglafayette',
    24,
    NULL::integer,
    'LCG official events calendar (Vision CMS). Government/civic events plus PARC community programming: workshops, fitness camps, community meetings.'
  )
) AS s(name, url, source_type, scrape_interval_hours, date_window_days, notes)
JOIN public.cities c ON c.slug = 'lafayette'
ON CONFLICT (url) DO UPDATE
  SET
    name                  = EXCLUDED.name,
    source_type           = EXCLUDED.source_type,
    scrape_interval_hours = EXCLUDED.scrape_interval_hours,
    notes                 = EXCLUDED.notes,
    updated_at            = now();
