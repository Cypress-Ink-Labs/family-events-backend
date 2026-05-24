/*
  Enrichment attempt tracking — break the centroid livelock
  ---------------------------------------------------------

  The backfill-event-enrichment cron was stuck reprocessing the same top-12
  rows every tick. Two interacting bugs:

    1. private.list_events_needing_enrichment orders by created_at DESC,
       which never changes, so the newest 12 unfillable rows (libcal events
       whose `address` is a room label like "Meeting Room (2nd), Main
       Library") permanently occupy the top of the queue.

    2. backfill-event-enrichment/index.ts had a city-centroid fallback that
       wrote the city's lat/lng back when Nominatim returned no hit. The
       updated row still matched centroid → still flagged needs_coords →
       claimed again next tick. The other ~1080 rows in the backlog never
       got a turn.

  Fix:

    - Add events.last_enrichment_attempt_at. Bumped on every enrichment
      attempt (success OR no-op).
    - Order both claim RPCs by last_enrichment_attempt_at ASC NULLS FIRST,
      then existing tiebreaker. First pass walks the NULL backlog; from
      then on the oldest-attempted rows surface first.
    - Add private.mark_event_enrichment_attempt(p_event_id) for the
      no-op path (geocode failed, no images written) so the row still
      moves to the back of the queue.
    - update_event_enrichment now also bumps last_enrichment_attempt_at.

  The city-centroid fallback in the edge function is removed in the
  accompanying TS change (backfill-event-enrichment/index.ts).
*/

BEGIN;

ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS last_enrichment_attempt_at timestamptz;

CREATE INDEX IF NOT EXISTS events_enrichment_attempt_idx
  ON public.events (last_enrichment_attempt_at NULLS FIRST, created_at DESC);

-- Drop wrappers + impl so we can change ORDER BY (PG allows CREATE OR REPLACE
-- for body changes but RETURNS TABLE shape is unchanged here so a plain
-- CREATE OR REPLACE would also work; the explicit DROP keeps the migration
-- symmetric with 20260601009100 which did need the drop).
DROP FUNCTION IF EXISTS public.list_events_needing_enrichment(int);
DROP FUNCTION IF EXISTS private.list_events_needing_enrichment(int);

CREATE OR REPLACE FUNCTION private.list_events_needing_enrichment(p_limit int DEFAULT 25)
RETURNS TABLE (
  event_id      uuid,
  title         text,
  description   text,
  venue_name    text,
  address       text,
  city_id       uuid,
  source_id     uuid,
  source_url    text,
  needs_coords  boolean,
  needs_images  boolean,
  admin_locked_fields text[],
  tags          text[]
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH enrichment_flags AS (
    SELECT
      e.*,
      (
        (
          e.latitude IS NULL
          OR e.longitude IS NULL
          OR (
            c.latitude IS NOT NULL
            AND c.longitude IS NOT NULL
            AND e.latitude IS NOT NULL
            AND e.longitude IS NOT NULL
            AND abs(e.latitude  - c.latitude)  < 0.000001
            AND abs(e.longitude - c.longitude) < 0.000001
          )
        )
        AND NOT 'latitude'  = ANY(e.admin_locked_fields)
        AND NOT 'longitude' = ANY(e.admin_locked_fields)
      ) AS _needs_coords,
      (
        (e.images = '[]'::jsonb OR jsonb_array_length(e.images) = 0)
        AND NOT 'images' = ANY(e.admin_locked_fields)
      ) AS _needs_images
    FROM public.events e
    LEFT JOIN public.cities c ON c.id = e.city_id
  ),
  event_tag_slugs AS (
    SELECT
      et.event_id,
      array_agg(t.slug ORDER BY et.confidence DESC NULLS LAST, t.slug ASC) AS slugs
    FROM public.event_tags et
    JOIN public.tags t ON t.id = et.tag_id
    GROUP BY et.event_id
  )
  SELECT
    ef.id,
    ef.title,
    ef.description,
    ef.venue_name,
    ef.address,
    ef.city_id,
    ef.source_id,
    ef.source_url,
    ef._needs_coords  AS needs_coords,
    ef._needs_images  AS needs_images,
    ef.admin_locked_fields,
    COALESCE(ets.slugs, ARRAY[]::text[]) AS tags
  FROM enrichment_flags ef
  LEFT JOIN event_tag_slugs ets ON ets.event_id = ef.id
  WHERE ef._needs_coords OR ef._needs_images
  ORDER BY ef.last_enrichment_attempt_at ASC NULLS FIRST, ef.created_at DESC
  LIMIT GREATEST(1, LEAST(p_limit, 100));
$$;

REVOKE EXECUTE ON FUNCTION private.list_events_needing_enrichment(int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.list_events_needing_enrichment(int) TO service_role;

CREATE OR REPLACE FUNCTION public.list_events_needing_enrichment(p_limit int DEFAULT 25)
RETURNS TABLE (
  event_id      uuid,
  title         text,
  description   text,
  venue_name    text,
  address       text,
  city_id       uuid,
  source_id     uuid,
  source_url    text,
  needs_coords  boolean,
  needs_images  boolean,
  admin_locked_fields text[],
  tags          text[]
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT * FROM private.list_events_needing_enrichment(p_limit);
$$;

REVOKE EXECUTE ON FUNCTION public.list_events_needing_enrichment(int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.list_events_needing_enrichment(int) TO service_role;

-- backfill_image_enrichment_in_scope has the same livelock risk: featured
-- rows or upcoming rows whose Unsplash tag lookup keeps returning nothing
-- would otherwise re-claim every tick.
DROP FUNCTION IF EXISTS public.backfill_image_enrichment_in_scope(int);
DROP FUNCTION IF EXISTS private.backfill_image_enrichment_in_scope(int);

CREATE OR REPLACE FUNCTION private.backfill_image_enrichment_in_scope(p_limit int DEFAULT 25)
RETURNS TABLE (
  event_id      uuid,
  title         text,
  description   text,
  venue_name    text,
  address       text,
  city_id       uuid,
  source_id     uuid,
  source_url    text,
  needs_coords  boolean,
  needs_images  boolean,
  admin_locked_fields text[],
  tags          text[]
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH scoped AS (
    SELECT e.*
    FROM public.events e
    WHERE e.status = 'published'
      AND (e.images = '[]'::jsonb OR jsonb_array_length(e.images) = 0)
      AND NOT 'images' = ANY(e.admin_locked_fields)
      AND (
        e.is_featured = true
        OR (e.start_datetime BETWEEN now() AND now() + interval '30 days')
      )
  ),
  event_tag_slugs AS (
    SELECT
      et.event_id,
      array_agg(t.slug ORDER BY et.confidence DESC NULLS LAST, t.slug ASC) AS slugs
    FROM public.event_tags et
    JOIN public.tags t ON t.id = et.tag_id
    GROUP BY et.event_id
  )
  SELECT
    s.id,
    s.title,
    s.description,
    s.venue_name,
    s.address,
    s.city_id,
    s.source_id,
    s.source_url,
    false                                                    AS needs_coords,
    true                                                     AS needs_images,
    s.admin_locked_fields,
    COALESCE(ets.slugs, ARRAY[]::text[])                     AS tags
  FROM scoped s
  LEFT JOIN event_tag_slugs ets ON ets.event_id = s.id
  ORDER BY s.last_enrichment_attempt_at ASC NULLS FIRST,
           s.is_featured DESC,
           s.start_datetime ASC
  LIMIT GREATEST(1, LEAST(p_limit, 100));
$$;

REVOKE EXECUTE ON FUNCTION private.backfill_image_enrichment_in_scope(int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.backfill_image_enrichment_in_scope(int) TO service_role;

CREATE OR REPLACE FUNCTION public.backfill_image_enrichment_in_scope(p_limit int DEFAULT 25)
RETURNS TABLE (
  event_id      uuid,
  title         text,
  description   text,
  venue_name    text,
  address       text,
  city_id       uuid,
  source_id     uuid,
  source_url    text,
  needs_coords  boolean,
  needs_images  boolean,
  admin_locked_fields text[],
  tags          text[]
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT * FROM private.backfill_image_enrichment_in_scope(p_limit);
$$;

REVOKE EXECUTE ON FUNCTION public.backfill_image_enrichment_in_scope(int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.backfill_image_enrichment_in_scope(int) TO service_role;

-- update_event_enrichment now also bumps last_enrichment_attempt_at so
-- successful writes count as an attempt and roll to the back of the queue.
CREATE OR REPLACE FUNCTION private.update_event_enrichment(
  p_event_id   uuid,
  p_latitude   numeric,
  p_longitude  numeric,
  p_images     jsonb
)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
  UPDATE public.events e SET
    latitude = CASE
      WHEN 'latitude' = ANY(e.admin_locked_fields) THEN e.latitude
      WHEN p_latitude IS NULL THEN e.latitude
      ELSE p_latitude
    END,
    longitude = CASE
      WHEN 'longitude' = ANY(e.admin_locked_fields) THEN e.longitude
      WHEN p_longitude IS NULL THEN e.longitude
      ELSE p_longitude
    END,
    images = CASE
      WHEN 'images' = ANY(e.admin_locked_fields) THEN e.images
      WHEN p_images IS NULL OR jsonb_array_length(p_images) = 0 THEN e.images
      ELSE p_images
    END,
    last_enrichment_attempt_at = now(),
    updated_at = now()
  WHERE e.id = p_event_id;
$$;

REVOKE EXECUTE ON FUNCTION private.update_event_enrichment(uuid, numeric, numeric, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.update_event_enrichment(uuid, numeric, numeric, jsonb) TO service_role;

-- Public wrapper unchanged in shape; recreate the body so the comment
-- about the attempt-timestamp side effect stays in one place.
CREATE OR REPLACE FUNCTION public.update_event_enrichment(
  p_event_id   uuid,
  p_latitude   numeric,
  p_longitude  numeric,
  p_images     jsonb
)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.update_event_enrichment(p_event_id, p_latitude, p_longitude, p_images);
$$;

REVOKE EXECUTE ON FUNCTION public.update_event_enrichment(uuid, numeric, numeric, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.update_event_enrichment(uuid, numeric, numeric, jsonb) TO service_role;

-- No-op attempt marker. Edge function calls this when an enrichment pass
-- produced neither coords nor images so the row still rotates out of the
-- front of the claim queue.
CREATE OR REPLACE FUNCTION private.mark_event_enrichment_attempt(p_event_id uuid)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
  UPDATE public.events
  SET last_enrichment_attempt_at = now()
  WHERE id = p_event_id;
$$;

REVOKE EXECUTE ON FUNCTION private.mark_event_enrichment_attempt(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.mark_event_enrichment_attempt(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.mark_event_enrichment_attempt(p_event_id uuid)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.mark_event_enrichment_attempt(p_event_id);
$$;

REVOKE EXECUTE ON FUNCTION public.mark_event_enrichment_attempt(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mark_event_enrichment_attempt(uuid) TO service_role;

COMMIT;
