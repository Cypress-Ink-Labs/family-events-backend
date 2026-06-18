-- Rollback for 20260601007000_lafayette_new_sources.sql
-- Removes the three iCal sources the migration inserted and reverts the Acadiana
-- Center for the Arts URL fix.
-- NOTE: the ACA revert restores '/events/' — the pre-migration value per the UP
-- migration's own WHERE clause. The three deleted sources were introduced by this
-- migration (so the DELETE only removes migration-added rows). No constraint change
-- here, so nothing else to restore.
BEGIN;

DELETE FROM public.event_sources
WHERE url IN (
  'https://thelafayettemom.com/events/?ical=1',
  'https://hilliardartmuseum.org/events/?ical=1',
  'https://bayouvermiliondistrict.org/events/?ical=1'
);

UPDATE public.event_sources
SET url = 'https://acadianacenterforthearts.org/events/', updated_at = now()
WHERE url = 'https://acadianacenterforthearts.org/whats-happening/'
  AND name = 'Acadiana Center for the Arts';

COMMIT;
