
-- ============================================================================
-- Source: 20260601006700_reference_data.sql
-- ============================================================================

/*
  # Family Events reference data

  Production reset baseline data. This is intentionally separate from
  supabase/seed.sql, which creates a local-only auth/admin account.

  Current source decisions baked in:
  - BREC uses the dedicated `brec` parser from the start.
  - Lafayette Macaroni Kid is included with its API date window.
  - East Baton Rouge Parish Library is omitted because the old LibCal RSS feed
    was empty and the real source requires a separate LocalHop integration.
*/

-- =============================================
-- Cities
-- =============================================
INSERT INTO public.cities (name, state, country, slug, latitude, longitude, timezone)
VALUES
  ('Baton Rouge', 'LA', 'US', 'baton-rouge', 30.4515, -91.1871, 'America/Chicago'),
  ('Lafayette', 'LA', 'US', 'lafayette', 30.2241, -92.0198, 'America/Chicago')
ON CONFLICT (slug) DO UPDATE
SET
  name = EXCLUDED.name,
  state = EXCLUDED.state,
  country = EXCLUDED.country,
  latitude = EXCLUDED.latitude,
  longitude = EXCLUDED.longitude,
  timezone = EXCLUDED.timezone;

-- =============================================
-- Tags
-- =============================================
INSERT INTO public.tags (name, slug, color, category, is_system)
VALUES
  ('Free', 'free', '#16a34a', 'cost', true),
  ('Outdoor', 'outdoor', '#15803d', 'location', true),
  ('Indoor', 'indoor', '#0369a1', 'location', true),
  ('Toddler-Friendly', 'toddler-friendly', '#d97706', 'age', true),
  ('Baby-Friendly', 'baby-friendly', '#f59e0b', 'age', true),
  ('Teen-Friendly', 'teen-friendly', '#7c3aed', 'age', true),
  ('Weekend', 'weekend', '#db2777', 'time', true),
  ('Educational', 'educational', '#0284c7', 'theme', true),
  ('Arts & Crafts', 'arts-crafts', '#c026d3', 'activity', true),
  ('Music', 'music', '#ea580c', 'activity', true),
  ('Sensory-Friendly', 'sensory-friendly', '#0891b2', 'theme', true),
  ('Family Festival', 'family-festival', '#dc2626', 'theme', true),
  ('Storytime', 'storytime', '#65a30d', 'activity', true),
  ('STEM', 'stem', '#2563eb', 'theme', true),
  ('Sports', 'sports', '#16a34a', 'activity', true),
  ('Cooking', 'cooking', '#d97706', 'activity', true),
  ('Nature', 'nature', '#15803d', 'theme', true),
  ('Community', 'community', '#6d28d9', 'theme', true),
  ('Holiday', 'holiday', '#dc2626', 'theme', true),
  ('Playgroup', 'playgroup', '#0891b2', 'activity', true)
ON CONFLICT (slug) DO UPDATE
SET
  name = EXCLUDED.name,
  color = EXCLUDED.color,
  category = EXCLUDED.category,
  is_system = EXCLUDED.is_system;

-- =============================================
-- Event Sources
-- =============================================
WITH source_data AS (
  SELECT
    'BREC Parks'::text AS name,
    'https://www.brec.org/calendar'::text AS url,
    'brec'::text AS source_type,
    'baton-rouge'::text AS city_slug,
    12::integer AS scrape_interval_hours,
    NULL::integer AS date_window_days,
    'Baton Rouge parks and recreation calendar'::text AS notes
  UNION ALL SELECT
    'Eventbrite Baton Rouge Family',
    'https://www.eventbrite.com/d/la--baton-rouge/family-events/',
    'website', 'baton-rouge', 12, NULL,
    'Family-friendly Eventbrite listings for Baton Rouge'
  UNION ALL SELECT
    'AllEvents Baton Rouge Family',
    'https://allevents.in/baton-rouge/family',
    'website', 'baton-rouge', 12, NULL,
    'AllEvents family listings for Baton Rouge'
  UNION ALL SELECT
    'Moncus Park',
    'https://moncuspark.org/events/',
    'website', 'lafayette', 12, NULL,
    'Outdoor family events at Moncus Park'
  UNION ALL SELECT
    'Acadiana Center for the Arts',
    'https://acadianacenterforthearts.org/events/',
    'website', 'lafayette', 12, NULL,
    'Arts and culture events in Lafayette'
  UNION ALL SELECT
    'Lafayette Science Museum',
    'https://lafayettesciencemuseum.org/events',
    'website', 'lafayette', 12, NULL,
    'Science museum family events'
  UNION ALL SELECT
    'Lafayette Public Library',
    'https://lafayettela.libcal.com/ical_subscribe.php?src=p&cid=11334',
    'ical', 'lafayette', 6, NULL,
    'Library story times and kids programming via LibCal iCal feed'
  UNION ALL SELECT
    'Eventbrite Lafayette Family',
    'https://www.eventbrite.com/d/la--lafayette/family-events/',
    'website', 'lafayette', 12, NULL,
    'Family-friendly Eventbrite listings for Lafayette'
  UNION ALL SELECT
    'AllEvents Lafayette Family',
    'https://allevents.in/lafayette/family',
    'website', 'lafayette', 12, NULL,
    'AllEvents family listings for Lafayette'
  UNION ALL SELECT
    'Macaroni Kid Lafayette',
    'https://lafayettela.macaronikid.com/events',
    'macaronikid', 'lafayette', 12, 90,
    'JSON API; two-hop fetch (page -> townId -> api.macaronikid.com).'
)
INSERT INTO public.event_sources (
  name,
  url,
  source_type,
  city_id,
  is_active,
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
  s.scrape_interval_hours,
  s.date_window_days,
  s.notes
FROM source_data s
JOIN public.cities c ON c.slug = s.city_slug
ON CONFLICT (url) DO UPDATE
SET
  name = EXCLUDED.name,
  source_type = EXCLUDED.source_type,
  city_id = EXCLUDED.city_id,
  is_active = EXCLUDED.is_active,
  scrape_interval_hours = EXCLUDED.scrape_interval_hours,
  date_window_days = EXCLUDED.date_window_days,
  notes = EXCLUDED.notes,
  updated_at = now();


-- ============================================================================
-- Source: 20260601006800_security_performance_hardening.sql
-- ============================================================================

-- Security and performance hardening from the Supabase/backend architecture audit.
-- Keep this additive so production rollout order stays reviewable.

-- ---------------------------------------------------------------------------
-- Cron observability RPCs: make admin reads explicit and service logging private.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_list_railway_cron_jobs()
RETURNS TABLE(
  label text,
  last_run_status text,
  last_run_at timestamp with time zone,
  last_run_duration_s integer,
  last_http_status integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'admin access required' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT *
  FROM private.list_railway_cron_jobs();
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_railway_cron_run_history(
  p_label text DEFAULT NULL::text,
  p_limit integer DEFAULT 50
)
RETURNS TABLE(
  id bigint,
  label text,
  status text,
  http_status integer,
  duration_s integer,
  body text,
  ran_at timestamp with time zone
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'admin access required' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT *
  FROM private.railway_cron_run_history(p_label, p_limit);
END;
$$;

CREATE OR REPLACE FUNCTION public.log_railway_cron_run(
  p_label text,
  p_status text,
  p_http_status integer DEFAULT NULL::integer,
  p_duration_s integer DEFAULT NULL::integer,
  p_body text DEFAULT NULL::text
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path TO ''
AS $$
  SELECT private.log_railway_cron_run(p_label, p_status, p_http_status, p_duration_s, p_body);
$$;

REVOKE ALL ON FUNCTION private.list_railway_cron_jobs() FROM PUBLIC;
REVOKE ALL ON FUNCTION private.list_railway_cron_jobs() FROM anon;
REVOKE ALL ON FUNCTION private.list_railway_cron_jobs() FROM authenticated;
REVOKE ALL ON FUNCTION private.log_railway_cron_run(text, text, integer, integer, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.log_railway_cron_run(text, text, integer, integer, text) FROM anon;
REVOKE ALL ON FUNCTION private.log_railway_cron_run(text, text, integer, integer, text) FROM authenticated;
REVOKE ALL ON FUNCTION private.railway_cron_run_history(text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.railway_cron_run_history(text, integer) FROM anon;
REVOKE ALL ON FUNCTION private.railway_cron_run_history(text, integer) FROM authenticated;
REVOKE ALL ON FUNCTION public.log_railway_cron_run(text, text, integer, integer, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.log_railway_cron_run(text, text, integer, integer, text) FROM anon;
REVOKE ALL ON FUNCTION public.log_railway_cron_run(text, text, integer, integer, text) FROM authenticated;
GRANT ALL ON FUNCTION public.log_railway_cron_run(text, text, integer, integer, text) TO service_role;

REVOKE ALL ON FUNCTION public.update_event_search_vector() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_event_search_vector() FROM anon;
REVOKE ALL ON FUNCTION public.update_event_search_vector() FROM authenticated;

-- Future functions must be granted intentionally. Existing function grants are
-- left in place unless tightened above to avoid a broad production break.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON FUNCTIONS FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON FUNCTIONS FROM authenticated;

-- ---------------------------------------------------------------------------
-- RLS helper performance: evaluate private.is_admin() once per statement.
-- ---------------------------------------------------------------------------

ALTER POLICY "Admins can delete cities" ON public.cities
  USING ((SELECT private.is_admin()));
ALTER POLICY "Admins can delete event tags" ON public.event_tags
  USING ((SELECT private.is_admin()));
ALTER POLICY "Admins can delete events" ON public.events
  USING ((SELECT private.is_admin()));
ALTER POLICY "Admins can delete sources" ON public.event_sources
  USING ((SELECT private.is_admin()));
ALTER POLICY "Admins can delete tags" ON public.tags
  USING ((SELECT private.is_admin()));

ALTER POLICY "Admins can insert audit log" ON public.admin_audit_log
  WITH CHECK ((SELECT private.is_admin()));
ALTER POLICY "Admins can insert cities" ON public.cities
  WITH CHECK ((SELECT private.is_admin()));
ALTER POLICY "Admins can insert event tags" ON public.event_tags
  WITH CHECK ((SELECT private.is_admin()));
ALTER POLICY "Admins can insert events" ON public.events
  WITH CHECK ((SELECT private.is_admin()));
ALTER POLICY "Admins can insert source runs" ON public.source_runs
  WITH CHECK ((SELECT private.is_admin()));
ALTER POLICY "Admins can insert sources" ON public.event_sources
  WITH CHECK ((SELECT private.is_admin()));
ALTER POLICY "Admins can insert tags" ON public.tags
  WITH CHECK ((SELECT private.is_admin()));

ALTER POLICY "Admins can manage invite codes" ON public.invite_codes
  USING ((SELECT private.is_admin()))
  WITH CHECK ((SELECT private.is_admin()));

ALTER POLICY "Admins can read AI traces" ON public.event_ai_traces
  USING ((SELECT private.is_admin()));
ALTER POLICY "Admins can read audit log" ON public.admin_audit_log
  USING ((SELECT private.is_admin()));
ALTER POLICY "Admins can read invite redemption attempts" ON public.invite_redemption_attempts
  USING ((SELECT private.is_admin()));
ALTER POLICY "Admins can read invite request attempts" ON public.invite_request_attempts
  USING ((SELECT private.is_admin()));
ALTER POLICY "Admins can read invite requests" ON public.invite_requests
  USING ((SELECT private.is_admin()));
ALTER POLICY "Admins can read source extraction traces" ON public.source_extraction_traces
  USING ((SELECT private.is_admin()));
ALTER POLICY "Admins can read source scrape queue" ON public.source_scrape_queue
  USING ((SELECT private.is_admin()));
ALTER POLICY "Admins can read tag queue" ON public.event_tag_queue
  USING ((SELECT private.is_admin()));
ALTER POLICY "Admins can select source runs" ON public.source_runs
  USING ((SELECT private.is_admin()));
ALTER POLICY "Admins can select sources" ON public.event_sources
  USING ((SELECT private.is_admin()));

ALTER POLICY "Admins can update cities" ON public.cities
  USING ((SELECT private.is_admin()))
  WITH CHECK ((SELECT private.is_admin()));
ALTER POLICY "Admins can update event tags" ON public.event_tags
  USING ((SELECT private.is_admin()))
  WITH CHECK ((SELECT private.is_admin()));
ALTER POLICY "Admins can update events" ON public.events
  USING ((SELECT private.is_admin()))
  WITH CHECK ((SELECT private.is_admin()));
ALTER POLICY "Admins can update sources" ON public.event_sources
  USING ((SELECT private.is_admin()))
  WITH CHECK ((SELECT private.is_admin()));
ALTER POLICY "Admins can update tags" ON public.tags
  USING ((SELECT private.is_admin()))
  WITH CHECK ((SELECT private.is_admin()));

-- ---------------------------------------------------------------------------
-- Search: use the existing events.search_vector GIN index for normal keywords.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.search_events(
  p_city_id uuid DEFAULT NULL::uuid,
  p_date_from timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_date_to timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_age_min integer DEFAULT NULL::integer,
  p_age_max integer DEFAULT NULL::integer,
  p_is_free boolean DEFAULT NULL::boolean,
  p_is_featured boolean DEFAULT NULL::boolean,
  p_tag_slugs text[] DEFAULT NULL::text[],
  p_keyword text DEFAULT NULL::text,
  p_status text DEFAULT 'published'::text,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
RETURNS SETOF public.events
LANGUAGE sql
STABLE
SET search_path TO ''
AS $$
  WITH search_input AS (
    SELECT
      CASE
        WHEN p_keyword IS NULL OR btrim(p_keyword) = '' OR length(p_keyword) > 100 THEN NULL::text
        ELSE btrim(p_keyword)
      END AS kw,
      CASE
        WHEN p_keyword IS NULL OR btrim(p_keyword) = '' OR length(p_keyword) > 100 THEN NULL::tsquery
        ELSE websearch_to_tsquery('english', btrim(p_keyword))
      END AS tsq,
      CASE
        WHEN p_keyword IS NULL OR btrim(p_keyword) = '' OR length(p_keyword) > 100 THEN NULL::text
        ELSE replace(replace(replace(btrim(p_keyword), '\', '\\'), '%', '\%'), '_', '\_')
      END AS escaped_kw
  )
  SELECT e.*
  FROM public.events e
  CROSS JOIN search_input si
  WHERE e.status = p_status
    AND (p_city_id IS NULL OR e.city_id = p_city_id)
    AND (p_date_from IS NULL OR e.start_datetime >= p_date_from)
    AND (p_date_to IS NULL OR e.start_datetime <= p_date_to)
    AND (p_is_free IS NULL OR e.is_free = p_is_free)
    AND (p_is_featured IS NULL OR e.is_featured = p_is_featured)
    AND (p_age_min IS NULL OR COALESCE(e.age_max, 99) >= p_age_min)
    AND (p_age_max IS NULL OR COALESCE(e.age_min, 0) <= p_age_max)
    AND (
      si.kw IS NULL
      OR (
        si.tsq IS NOT NULL
        AND numnode(si.tsq) > 0
        AND e.search_vector @@ si.tsq
      )
      OR (
        si.escaped_kw IS NOT NULL
        AND (numnode(si.tsq) = 0 OR length(si.kw) < 3)
        AND (
          e.title ILIKE '%' || si.escaped_kw || '%' ESCAPE '\'
          OR e.description ILIKE '%' || si.escaped_kw || '%' ESCAPE '\'
        )
      )
    )
    AND (
      p_tag_slugs IS NULL
      OR array_length(p_tag_slugs, 1) IS NULL
      OR (
        SELECT COUNT(DISTINCT t.slug)
        FROM public.event_tags et
        JOIN public.tags t ON t.id = et.tag_id
        WHERE et.event_id = e.id AND t.slug = ANY(p_tag_slugs)
      ) = array_length(p_tag_slugs, 1)
    )
  ORDER BY
    CASE
      WHEN si.tsq IS NULL OR numnode(si.tsq) = 0 THEN NULL::real
      ELSE ts_rank_cd(e.search_vector, si.tsq)
    END DESC NULLS LAST,
    e.start_datetime ASC,
    e.id ASC
  LIMIT LEAST(GREATEST(p_limit, 0), 500)
  OFFSET GREATEST(p_offset, 0);
$$;

-- ---------------------------------------------------------------------------
-- Due-source selection: keep scheduled scrape filtering in SQL, not Edge JS.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.due_event_sources(p_limit integer DEFAULT 200)
RETURNS SETOF public.event_sources
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $$
  SELECT s.*
  FROM public.event_sources s
  WHERE s.is_active = true
    AND (
      s.last_scraped_at IS NULL
      OR s.last_scraped_at + make_interval(hours => s.scrape_interval_hours) <= now()
    )
  ORDER BY s.last_scraped_at ASC NULLS FIRST, s.id ASC
  LIMIT LEAST(GREATEST(p_limit, 1), 500);
$$;

REVOKE ALL ON FUNCTION public.due_event_sources(integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.due_event_sources(integer) TO service_role;

-- ---------------------------------------------------------------------------
-- Data integrity. Add NOT VALID first so production can clean existing data.
-- ---------------------------------------------------------------------------

ALTER TABLE public.events
  ADD CONSTRAINT events_age_range_chk
  CHECK (
    (age_min IS NULL OR age_min >= 0)
    AND (age_max IS NULL OR age_max >= 0)
    AND (age_min IS NULL OR age_max IS NULL OR age_min <= age_max)
  ) NOT VALID;

ALTER TABLE public.events
  ADD CONSTRAINT events_lat_lng_chk
  CHECK (
    (latitude IS NULL OR latitude BETWEEN -90 AND 90)
    AND (longitude IS NULL OR longitude BETWEEN -180 AND 180)
  ) NOT VALID;

ALTER TABLE public.events
  ADD CONSTRAINT events_price_chk
  CHECK (price IS NULL OR price >= 0) NOT VALID;

ALTER TABLE public.user_profiles
  ADD CONSTRAINT user_profiles_child_age_chk
  CHECK (child_age IS NULL OR child_age BETWEEN 0 AND 18) NOT VALID;

ALTER TABLE public.invite_codes
  ADD CONSTRAINT invite_codes_used_count_max_chk
  CHECK (used_count <= max_uses) NOT VALID;

ALTER TABLE public.event_sources
  ADD CONSTRAINT event_sources_scrape_interval_chk
  CHECK (scrape_interval_hours BETWEEN 1 AND 720) NOT VALID;

-- ---------------------------------------------------------------------------
-- Additive indexes for confirmed access patterns. Do not drop old indexes until
-- production pg_stat_user_indexes and EXPLAIN evidence confirm redundancy.
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS events_published_feed_idx
  ON public.events (city_id, start_datetime, id)
  WHERE status = 'published';

CREATE INDEX IF NOT EXISTS events_admin_created_idx
  ON public.events (created_at DESC, id);

CREATE INDEX IF NOT EXISTS events_admin_status_created_idx
  ON public.events (status, created_at DESC, id);

CREATE INDEX IF NOT EXISTS events_published_local_date_city_idx
  ON public.events (((start_datetime AT TIME ZONE timezone)::date), city_id, id)
  WHERE status = 'published';

CREATE INDEX IF NOT EXISTS event_tag_queue_event_id_idx
  ON public.event_tag_queue (event_id);

CREATE INDEX IF NOT EXISTS source_scrape_queue_source_id_idx
  ON public.source_scrape_queue (source_id)
  WHERE source_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS source_runs_started_at_idx
  ON public.source_runs (started_at DESC, id);

CREATE INDEX IF NOT EXISTS source_runs_source_error_started_idx
  ON public.source_runs (source_id, started_at DESC)
  WHERE status = 'error' AND error_log IS NOT NULL;

CREATE INDEX IF NOT EXISTS event_sources_active_last_scraped_idx
  ON public.event_sources (last_scraped_at, id)
  WHERE is_active = true;

CREATE INDEX IF NOT EXISTS admin_audit_log_target_idx
  ON public.admin_audit_log (target_type, target_id, created_at DESC)
  WHERE target_id IS NOT NULL;


-- ============================================================================
-- Source: 20260601006900_railway_cron_toggle.sql
-- ============================================================================

/*
  # Toggleable Railway crons

  Railway cron services have no native pause API, so toggling them from the
  admin UI requires a DB-side kill switch the runner consults each tick.

  Adds:
    - private.cron_enabled (label PK, enabled BOOLEAN, updated_at)
    - public.is_cron_enabled(label) — anon/service callable boolean check
    - public.admin_set_cron_enabled(label, enabled) — admin-only toggle wrapper
    - admin_list_railway_cron_jobs now returns the `enabled` flag so the UI
      card knows the current state.

  Default state: enabled=true for every known cron label. Toggling to false
  makes cron-runner.sh skip the main curl (next tick logs status='skipped').
*/

BEGIN;

-- =============================================
-- 1. cron_enabled table + seed
-- =============================================
CREATE TABLE IF NOT EXISTS private.cron_enabled (
  label      text        PRIMARY KEY,
  enabled    boolean     NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE private.cron_enabled IS
  'Per-label on/off switch for Railway cron services. Read by cron-runner.sh
   on every tick via public.is_cron_enabled. Toggled by admin UI via
   public.admin_set_cron_enabled. Decoupled from Railway cronSchedule so
   the schedule stays in railway.toml but the kill switch lives in the DB.';

INSERT INTO private.cron_enabled (label) VALUES
  ('cron-tag-queue'),
  ('cron-scrape-sources'),
  ('cron-db-maintenance'),
  ('cron-cleanup-stale')
ON CONFLICT (label) DO NOTHING;

-- =============================================
-- 2. private.is_cron_enabled body
-- =============================================
CREATE OR REPLACE FUNCTION private.is_cron_enabled(p_label text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(
    (SELECT enabled FROM private.cron_enabled WHERE label = p_label),
    true
  );
$$;

REVOKE EXECUTE ON FUNCTION private.is_cron_enabled(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.is_cron_enabled(text) TO service_role;

-- Public SECURITY INVOKER wrapper for PostgREST. service_role only — the
-- runner curls /rest/v1/rpc/is_cron_enabled with a Bearer sb_secret_* key.
CREATE OR REPLACE FUNCTION public.is_cron_enabled(p_label text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.is_cron_enabled(p_label);
$$;

REVOKE EXECUTE ON FUNCTION public.is_cron_enabled(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.is_cron_enabled(text) TO service_role;

-- =============================================
-- 3. admin_set_cron_enabled — admin-only toggle
-- =============================================
CREATE OR REPLACE FUNCTION private.admin_set_cron_enabled(p_label text, p_enabled boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  INSERT INTO private.cron_enabled (label, enabled, updated_at)
  VALUES (p_label, p_enabled, now())
  ON CONFLICT (label) DO UPDATE
    SET enabled = EXCLUDED.enabled,
        updated_at = now();
END;
$$;

REVOKE EXECUTE ON FUNCTION private.admin_set_cron_enabled(text, boolean) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.admin_set_cron_enabled(text, boolean) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_set_cron_enabled(p_label text, p_enabled boolean)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.admin_set_cron_enabled(p_label, p_enabled);
$$;

REVOKE EXECUTE ON FUNCTION public.admin_set_cron_enabled(text, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_set_cron_enabled(text, boolean) TO authenticated;

-- =============================================
-- 4. Extend list_railway_cron_jobs with enabled
--    RETURNS TABLE shape grows — Postgres rejects ALTER to OUT param
--    shape, so DROP both wrapper + body before recreating.
-- =============================================
DROP FUNCTION IF EXISTS public.admin_list_railway_cron_jobs();
DROP FUNCTION IF EXISTS private.list_railway_cron_jobs();

CREATE FUNCTION private.list_railway_cron_jobs()
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
      'cron-cleanup-stale'
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

REVOKE EXECUTE ON FUNCTION private.list_railway_cron_jobs() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.list_railway_cron_jobs() TO authenticated, service_role;

CREATE FUNCTION public.admin_list_railway_cron_jobs()
RETURNS TABLE (
  label               text,
  enabled             boolean,
  last_run_status     text,
  last_run_at         timestamptz,
  last_run_duration_s int,
  last_http_status    int
)
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT * FROM private.list_railway_cron_jobs();
$$;

REVOKE EXECUTE ON FUNCTION public.admin_list_railway_cron_jobs() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_list_railway_cron_jobs() TO authenticated;

COMMIT;

