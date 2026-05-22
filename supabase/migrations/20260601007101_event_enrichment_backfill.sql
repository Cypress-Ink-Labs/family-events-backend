/*
  # Event enrichment backfill

  Phase 2 of the bulk-scrape rewrite (20260601007000) intentionally dropped
  per-event geocode + image HEAD HTTP work from the scrape hot path — those
  HTTPs were the long pole on the 150s edge wall (460 new events × 2 HTTPs
  × 500ms = 460s+). The scrape RPC now leaves `latitude/longitude` NULL and
  `images = []` on freshly inserted rows.

  This migration adds the missing backfill plumbing:
    - private.list_events_needing_enrichment(p_limit) — claim batch of
      events where coords are NULL or images is empty AND the field isn't
      admin-locked. Returns the source's `url` + city context so the edge
      function has everything it needs without a second round-trip.
    - private.update_event_enrichment(p_event_id, p_latitude, p_longitude,
      p_images) — UPDATE events honoring admin_locked_fields per-field, so
      we never overwrite an admin's manual coord/image edit.
    - cron-enrich-events added to private.cron_enabled + the Railway
      allowlist (admin UI list_railway_cron_jobs).
*/

BEGIN;

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
  admin_locked_fields text[]
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    e.id,
    e.title,
    e.description,
    e.venue_name,
    e.address,
    e.city_id,
    e.source_id,
    e.source_url,
    (e.latitude IS NULL OR e.longitude IS NULL)
       AND NOT 'latitude'  = ANY(e.admin_locked_fields)
       AND NOT 'longitude' = ANY(e.admin_locked_fields)
       AS needs_coords,
    (e.images = '[]'::jsonb OR jsonb_array_length(e.images) = 0)
       AND NOT 'images' = ANY(e.admin_locked_fields)
       AS needs_images,
    e.admin_locked_fields
  FROM public.events e
  WHERE (
    (e.latitude IS NULL OR e.longitude IS NULL)
       AND NOT 'latitude'  = ANY(e.admin_locked_fields)
       AND NOT 'longitude' = ANY(e.admin_locked_fields)
  )
  OR (
    (e.images = '[]'::jsonb OR jsonb_array_length(e.images) = 0)
       AND NOT 'images' = ANY(e.admin_locked_fields)
  )
  ORDER BY e.created_at DESC
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
  admin_locked_fields text[]
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
    updated_at = now()
  WHERE e.id = p_event_id;
$$;

REVOKE EXECUTE ON FUNCTION private.update_event_enrichment(uuid, numeric, numeric, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.update_event_enrichment(uuid, numeric, numeric, jsonb) TO service_role;

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

-- Seed the new cron label so the UI toggle + runner kill switch both work.
INSERT INTO private.cron_enabled (label) VALUES ('cron-enrich-events')
ON CONFLICT (label) DO NOTHING;

-- Extend the Railway cron allowlist. RETURNS TABLE shape unchanged so we
-- can CREATE OR REPLACE the body without dropping the dependent wrapper.
CREATE OR REPLACE FUNCTION private.list_railway_cron_jobs()
RETURNS TABLE (
  label               text,
  enabled             boolean,
  last_run_status     text,
  last_run_at         timestamptz,
  last_run_duration_s int,
  last_http_status    int
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH known AS (
    SELECT unnest(ARRAY[
      'cron-db-maintenance',
      'cron-tag-queue',
      'cron-scrape-sources',
      'cron-cleanup-stale',
      'cron-enrich-events'
    ]::text[]) AS label
  ),
  last_runs AS (
    SELECT DISTINCT ON (r.label)
      r.label, r.status, r.ran_at, r.duration_s, r.http_status
    FROM private.railway_cron_runs r
    ORDER BY r.label, r.ran_at DESC
  )
  SELECT
    k.label,
    COALESCE((SELECT ce.enabled FROM private.cron_enabled ce WHERE ce.label = k.label), true) AS enabled,
    lr.status,
    lr.ran_at,
    lr.duration_s,
    lr.http_status
  FROM known k
  LEFT JOIN last_runs lr ON lr.label = k.label
  ORDER BY k.label;
END;
$$;

COMMIT;
