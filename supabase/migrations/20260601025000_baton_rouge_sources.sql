-- =============================================
-- Baton Rouge source expansion
-- Adds LocalHop as a deterministic source type and seeds higher-signal
-- Baton Rouge sources discovered during source research.
-- =============================================

-- Extend source_type check constraint for the LocalHop API parser.
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
    'lcglafayette'::text,
    'localhop'::text
  ]));

-- Insert new Baton Rouge sources (idempotent via ON CONFLICT on url).
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
    'BREC Kids Calendar',
    'https://www.brec.org/calendar/category/KidsCalendar',
    'brec',
    6,
    NULL::integer,
    'BREC category calendar focused on kids and family programming.'
  ),
  (
    'BREC Parks',
    'https://www.brec.org/calendar',
    'brec',
    12,
    NULL::integer,
    'Baton Rouge parks and recreation calendar; dedicated BREC parser handles event-list markup.'
  ),
  (
    'Baton Rouge Zoo',
    'https://brzoo.org/',
    'website',
    12,
    NULL::integer,
    'BREC Baton Rouge Zoo events. Website parser handles repeater-list event cards and occdate URLs.'
  ),
  (
    'Knock Knock Children''s Museum',
    'https://knockknockmuseum.org/calendar/',
    'website',
    12,
    NULL::integer,
    'Children''s museum calendar; existing website parser extracts structured calendar events.'
  ),
  (
    'LocalHop Baton Rouge',
    'https://events.getlocalhop.com/search?city=baton%20rouge&state=la&days=120&limit=100',
    'localhop',
    6,
    120,
    'LocalHop API-backed Baton Rouge event listings, including East Baton Rouge Parish Library programs.'
  ),
  (
    'Perkins Rowe Events',
    'https://perkinsrowe.com/happenings/',
    'website',
    12,
    NULL::integer,
    'Perkins Rowe happenings page. Website parser handles All-in-One Event Calendar popovers.'
  ),
  (
    'Manship Theatre',
    'https://manshiptheatre.org/',
    'website',
    24,
    NULL::integer,
    'Manship Theatre event summaries. Website parser handles Squarespace event cards.'
  ),
  (
    'City-Parish Main Calendar',
    'https://www.brla.gov/common/modules/iCalendar/iCalendar.aspx?catID=61&feed=calendar',
    'ical',
    24,
    NULL::integer,
    'Official Baton Rouge City-Parish main calendar iCal feed.'
  )
) AS s(name, url, source_type, scrape_interval_hours, date_window_days, notes)
JOIN public.cities c ON c.slug = 'baton-rouge'
ON CONFLICT (url) DO UPDATE
  SET
    name                  = EXCLUDED.name,
    source_type           = EXCLUDED.source_type,
    city_id               = EXCLUDED.city_id,
    is_active             = EXCLUDED.is_active,
    auto_approve          = EXCLUDED.auto_approve,
    scrape_interval_hours = EXCLUDED.scrape_interval_hours,
    date_window_days      = EXCLUDED.date_window_days,
    notes                 = EXCLUDED.notes,
    updated_at            = now();
