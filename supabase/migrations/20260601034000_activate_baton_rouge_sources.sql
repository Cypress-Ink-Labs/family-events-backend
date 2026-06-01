-- Activate Baton Rouge event sources.
-- These sources have working parsers (brec, ical, localhop) and cover
-- the main family event venues in the Baton Rouge metro area.

UPDATE public.event_sources
SET is_active = true
WHERE name IN (
  'BREC Parks',           -- brec parser, main recreation calendar
  'BREC Kids Calendar',   -- brec parser, kids-specific calendar
  'City-Parish Main Calendar', -- ical parser, government events
  'LocalHop Baton Rouge'  -- localhop parser, community events aggregator
);
