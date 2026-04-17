/*
  # Explicitly activate verified event sources

  The 005 seed file's UNION ALL CTE can produce unpredictable is_active values
  when run during both the migration phase and seed phase (idempotent inserts
  prevent re-insertion but the first pass occasionally gets type-inferred as the
  wrong boolean due to UNION ALL row ordering).

  This migration makes the intent explicit: set verified-working sources to
  active, and bot-protected / dead sources to inactive. Idempotent UPDATE.

  Verified working as of 2026-04-16:
    - BREC Family Events (website, brec.org)
    - Boston Public Library Events (RSS)
    - Chicago Public Library Events (RSS)
    - Louisville Zoo Events (iCal)
*/

UPDATE public.event_sources
SET is_active = true
WHERE url IN (
  'https://www.brec.org/calendar',
  'https://www.bpl.org/events/feed/',
  'https://www.chipublib.org/events/feed/',
  'https://www.louisvillezoo.org/events/?ical=1&tribe_display=list'
);

UPDATE public.event_sources
SET is_active = false
WHERE url IN (
  'https://www.nypl.org/events/rss',
  'https://www.nycgovparks.org/events',
  'https://www.bklynlibrary.org/calendar/feed',
  'https://library.austintexas.gov/events/feed',
  'https://www.denverlibrary.org/events/feed',
  'https://www.spl.org/calendar/rss',
  'https://www.chicagoparkdistrict.com/events',
  'https://www.portland.gov/parks/events'
);
