-- =============================================
-- New Lafayette-area event sources
-- Adds three iCal feeds (The Events Calendar WordPress plugin)
-- and fixes the Acadiana Center for the Arts URL.
--
-- Sources added:
--   Lafayette Mom          — https://thelafayettemom.com/events/?ical=1
--   Hilliard Art Museum    — https://hilliardartmuseum.org/events/?ical=1
--   Vermilionville         — https://bayouvermiliondistrict.org/events/?ical=1
--
-- Sources fixed:
--   Acadiana Center for the Arts: /events/ → /whats-happening/
--   (old URL returns 301; website parser was fetching a redirect target
--    that no longer exposes structured event markup)
-- =============================================

-- Fix existing broken ACA URL (no-op if already updated)
UPDATE public.event_sources
SET
  url        = 'https://acadianacenterforthearts.org/whats-happening/',
  updated_at = now()
WHERE url  = 'https://acadianacenterforthearts.org/events/'
  AND name = 'Acadiana Center for the Arts';

-- Insert new sources (idempotent via ON CONFLICT on url)
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
    'Lafayette Mom',
    'https://thelafayettemom.com/events/?ical=1',
    'ical',
    6,
    NULL::integer,
    'Family-focused community calendar; iCal feed from The Events Calendar plugin. 500+ events covering library programs, festivals, classes, and outdoor activities.'
  ),
  (
    'Hilliard Art Museum',
    'https://hilliardartmuseum.org/events/?ical=1',
    'ical',
    12,
    NULL::integer,
    'UL Lafayette art museum: guided tours, kids Create & Play Café, workshops, yoga in galleries. iCal from The Events Calendar plugin.'
  ),
  (
    'Vermilionville',
    'https://bayouvermiliondistrict.org/events/?ical=1',
    'ical',
    12,
    NULL::integer,
    'Bayou Vermilion District / Vermilionville living history village: weekly Cajun jams, Bal du Dimanche dances, Homeschool Days, seasonal festivals. iCal from The Events Calendar plugin.'
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
