/*
  # Macaroni Kid parser support

  - Extends the event_sources.source_type CHECK constraint to allow
    'macaronikid' (a JSON-API source type that fetches a public-facing HTML
    page to discover its townOwner id and then queries api.macaronikid.com).
  - Adds an optional date_window_days column so JSON-API parsers can scope
    their server-side queries to a finite forward window without hard-coding.
    Existing parsers (website/rss/ical) ignore it.
  - Seeds the Lafayette Macaroni Kid source.
*/

ALTER TABLE public.event_sources
  DROP CONSTRAINT IF EXISTS event_sources_source_type_check;

ALTER TABLE public.event_sources
  ADD CONSTRAINT event_sources_source_type_check
  CHECK (source_type IN ('website', 'ical', 'rss', 'manual', 'macaronikid'));

ALTER TABLE public.event_sources
  ADD COLUMN IF NOT EXISTS date_window_days integer;

INSERT INTO public.event_sources (
  name, url, source_type, city_id, is_active, scrape_interval_hours, date_window_days, notes
)
SELECT
  'Macaroni Kid Lafayette',
  'https://lafayettela.macaronikid.com/events',
  'macaronikid',
  c.id,
  true,
  12,
  90,
  'JSON API; two-hop fetch (page -> townId -> api.macaronikid.com).'
FROM public.cities c
WHERE c.slug = 'lafayette'
  AND NOT EXISTS (
    SELECT 1 FROM public.event_sources existing
    WHERE existing.url = 'https://lafayettela.macaronikid.com/events'
  );
