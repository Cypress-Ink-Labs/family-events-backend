/*
  # BREC parser support

  Extends event_sources.source_type CHECK constraint to allow 'brec'.
  Switches the existing "BREC Parks" source from generic 'website' to 'brec'
  so the dedicated brec.ts parser handles its day-header + article DOM
  structure. The brec.org/calendar page has no JSON-LD events, so the
  generic website parser returned zero events on every scrape.
*/

ALTER TABLE public.event_sources
  DROP CONSTRAINT IF EXISTS event_sources_source_type_check;

ALTER TABLE public.event_sources
  ADD CONSTRAINT event_sources_source_type_check
  CHECK (source_type IN ('website', 'ical', 'rss', 'manual', 'macaronikid', 'brec'));

UPDATE public.event_sources
SET source_type = 'brec'
WHERE id = '67a26cef-8948-4637-b280-ad103c115c73';
