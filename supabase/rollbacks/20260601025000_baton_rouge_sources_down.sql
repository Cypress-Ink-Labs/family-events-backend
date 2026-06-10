-- Rollback for 20260601025000_baton_rouge_sources.sql
-- Best-effort data rollback; sources with accumulated runs/events are
-- deactivated, not deleted.
--
-- Reverts:
--   - Drops 'localhop' from event_sources_source_type_check constraint
--     (restores prior 8-value check without 'localhop')
--   - Deactivates inserted sources matched by URL where dependent rows exist
--     (events.source_id or source_runs reference them)
--   - Deletes inserted sources only where no dependent rows reference them
--
-- DATA LOSS CAVEAT: sources with no dependents are permanently deleted.
-- Sources with accumulated runs/events are only deactivated (is_active=false).

BEGIN;

-- 1. Best-effort rollback of inserted event_sources rows.
--    Deactivate sources that have dependent rows (events or source_runs).
UPDATE public.event_sources
SET is_active = false,
    updated_at = now()
WHERE url IN (
  'https://www.brec.org/calendar/category/KidsCalendar',
  'https://www.brec.org/calendar',
  'https://brzoo.org/',
  'https://knockknockmuseum.org/calendar/',
  'https://events.getlocalhop.com/search?city=baton%20rouge&state=la&days=120&limit=100',
  'https://perkinsrowe.com/happenings/',
  'https://manshiptheatre.org/',
  'https://www.brla.gov/common/modules/iCalendar/iCalendar.aspx?catID=61&feed=calendar'
)
AND (
  EXISTS (SELECT 1 FROM public.events e WHERE e.source_id = event_sources.id)
  OR EXISTS (SELECT 1 FROM public.source_runs sr WHERE sr.source_id = event_sources.id)
);

-- 2. Delete sources that have no dependent rows at all.
DELETE FROM public.event_sources
WHERE url IN (
  'https://www.brec.org/calendar/category/KidsCalendar',
  'https://www.brec.org/calendar',
  'https://brzoo.org/',
  'https://knockknockmuseum.org/calendar/',
  'https://events.getlocalhop.com/search?city=baton%20rouge&state=la&days=120&limit=100',
  'https://perkinsrowe.com/happenings/',
  'https://manshiptheatre.org/',
  'https://www.brla.gov/common/modules/iCalendar/iCalendar.aspx?catID=61&feed=calendar'
)
AND NOT EXISTS (SELECT 1 FROM public.events e WHERE e.source_id = event_sources.id)
AND NOT EXISTS (SELECT 1 FROM public.source_runs sr WHERE sr.source_id = event_sources.id);

-- 3. Restore the source_type check constraint without 'localhop'.
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

COMMIT;
