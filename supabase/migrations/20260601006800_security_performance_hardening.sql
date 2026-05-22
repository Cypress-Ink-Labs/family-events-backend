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
