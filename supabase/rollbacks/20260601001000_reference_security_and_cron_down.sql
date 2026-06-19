-- Rollback for 20260601001000_reference_security_and_cron.sql
--
-- This UP migration is a concatenation of four legacy source files:
--   - 20260601006700_reference_data.sql            (cities/tags/event_sources seed upserts)
--   - 20260601006800_security_performance_hardening.sql (cron RPC grants, RLS perf, search_events,
--                                                         due_event_sources, 6 CHECK constraints, 10 indexes)
--   - 20260601006900_railway_cron_toggle.sql        (cron_enabled table, is_cron_enabled,
--                                                     admin_set_cron_enabled, list_railway_cron_jobs reshape)
--
-- CRITICAL CONTEXT — squashed baseline ambiguity:
-- The squashed snapshot supabase/migrations/20260601000000_schema_baseline.sql
-- (timestamp BEFORE this migration) is internally INCONSISTENT about what state
-- it captured. For some objects it captured the POST-001000 end-state; for others
-- the PRE-001000 state. We inverted ONLY the objects whose net effect this
-- migration genuinely introduced/changed relative to baseline, and we DELIBERATELY
-- LEAVE the objects that baseline already contains in their end-state (dropping
-- them would corrupt the baseline contract). See the STOP/REDUNDANT section below.
--
-- Prior-definition sources (all file:line in 20260601000000_schema_baseline.sql
-- unless noted):
--   * private.list_railway_cron_jobs()  prior 5-col body ........ baseline:2769-2791 (+ owner 2794)
--                                        prior grants ............. baseline:6242-6243
--   * public.admin_list_railway_cron_jobs() prior 5-col body ..... baseline:3441-3446 (+ owner 3449)
--                                        prior grants ............. baseline:6373-6375
--   * public.search_events(12-param) prior body ................. baseline:4187-4229 (+ owner 4232)
--                                        prior grants ............. baseline:6595-6597
--   * public.update_event_search_vector() prior grants .......... baseline:6606-6608
--   * ALTER DEFAULT PRIVILEGES ... FUNCTIONS prior grants ....... baseline:6867-6868
--   * 28 admin RLS policies prior (bare) USING/WITH CHECK exprs .. baseline:5383-5499
--
-- Ordering hazards:
--   1. private.list_railway_cron_jobs() is the dependency of
--      public.admin_list_railway_cron_jobs(). Drop the public wrapper FIRST, then
--      the private body, then recreate private body, then public wrapper (reverse
--      of the UP order, dependency-correct).
--   2. The 6-col -> 5-col reshape of these two functions changes the OUT-param
--      (RETURNS TABLE) shape, so they MUST be DROPped (not CREATE OR REPLACE)
--      before recreating, exactly as the UP migration did in the other direction.
--   3. public.admin_list_railway_cron_jobs depends on private.list_railway_cron_jobs
--      at body-validation time. With check_function_bodies=on (default), recreating
--      the public wrapper would fail if the private body does not yet exist — so we
--      recreate private first.
--
-- See the STOP / IRREVERSIBLE / REDUNDANT section at the bottom of this file for
-- the objects intentionally NOT reverted.

BEGIN;

-- ===========================================================================
-- 1. cron_enabled toggle functions introduced by this migration (net-new).
--    No prior definition existed in baseline -> inverse is DROP.
--    Drop public (invoker) wrappers before private (definer) bodies.
-- ===========================================================================
DROP FUNCTION IF EXISTS public.admin_set_cron_enabled(text, boolean);
DROP FUNCTION IF EXISTS private.admin_set_cron_enabled(text, boolean);
DROP FUNCTION IF EXISTS public.is_cron_enabled(text);
DROP FUNCTION IF EXISTS private.is_cron_enabled(text);

-- ===========================================================================
-- 2. list_railway_cron_jobs reshape (6-col enabled-aware -> baseline 5-col).
--    The UP did DROP+CREATE because RETURNS TABLE shape grew; we do the same in
--    reverse. Drop the 6-col public wrapper + private body, then recreate the
--    baseline 5-col forms verbatim.
-- ===========================================================================
DROP FUNCTION IF EXISTS public.admin_list_railway_cron_jobs();
DROP FUNCTION IF EXISTS private.list_railway_cron_jobs();

-- Restore baseline private.list_railway_cron_jobs() — body verbatim from
-- 20260601000000_schema_baseline.sql:2769-2791 (LANGUAGE sql, 5-col, no enabled,
-- no is_admin guard — the guard lived in the public path pre-toggle).
CREATE OR REPLACE FUNCTION private.list_railway_cron_jobs()
  RETURNS TABLE(
    label text,
    last_run_status text,
    last_run_at timestamp with time zone,
    last_run_duration_s integer,
    last_http_status integer
  )
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $$
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
  SELECT k.label, lr.status, lr.ran_at, lr.duration_s, lr.http_status
  FROM known k
  LEFT JOIN last_runs lr ON lr.label = k.label
  ORDER BY k.label;
$$;

ALTER FUNCTION private.list_railway_cron_jobs() OWNER TO postgres;

-- Restore baseline grants (baseline:6242-6243). The UP migration's
-- REVOKE FROM PUBLIC/anon/authenticated state is the same as baseline's, so we
-- only re-add the affirmative grants baseline carried.
REVOKE EXECUTE ON FUNCTION private.list_railway_cron_jobs() FROM PUBLIC, anon, authenticated;
GRANT ALL ON FUNCTION private.list_railway_cron_jobs() TO authenticated, service_role;

-- Restore baseline public.admin_list_railway_cron_jobs() — body verbatim from
-- 20260601000000_schema_baseline.sql:3441-3446 (LANGUAGE sql / SECURITY INVOKER,
-- 5-col passthrough of the private body).
CREATE OR REPLACE FUNCTION public.admin_list_railway_cron_jobs()
  RETURNS TABLE(
    label text,
    last_run_status text,
    last_run_at timestamp with time zone,
    last_run_duration_s integer,
    last_http_status integer
  )
  LANGUAGE sql
  SET search_path TO ''
  AS $$
  SELECT * FROM private.list_railway_cron_jobs();
$$;

ALTER FUNCTION public.admin_list_railway_cron_jobs() OWNER TO postgres;

-- Restore baseline grants (baseline:6373-6375).
REVOKE ALL ON FUNCTION public.admin_list_railway_cron_jobs() FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_list_railway_cron_jobs() TO authenticated, service_role;

-- ===========================================================================
-- 3. due_event_sources(integer) introduced by this migration (net-new).
--    Not present in baseline (grep: 0 matches) -> inverse is DROP.
-- ===========================================================================
DROP FUNCTION IF EXISTS public.due_event_sources(integer);

-- ===========================================================================
-- 4. search_events 12-param body REPLACE -> restore baseline body.
--    The UP migration replaced the simple ILIKE body with a full-text
--    (search_vector @@ tsq + ts_rank_cd) body. Restore the prior body verbatim
--    from 20260601000000_schema_baseline.sql:4187-4229.
--
--    HAZARD: later migrations (017000 enum-cast, 028000 radius, 032000 overload
--    cleanup) further evolve search_events. This rollback only undoes 001000, so
--    it restores the BASELINE body, which is correct for a single-step rollback
--    of 001000 applied immediately after baseline+000001. If later migrations are
--    already applied, roll those back first (their own *_down.sql files exist).
-- ===========================================================================
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
  WITH escaped_keyword AS (
    SELECT
      CASE
        WHEN p_keyword IS NULL OR p_keyword = '' THEN NULL
        WHEN length(p_keyword) > 100 THEN NULL
        -- Escape \, %, and _ so wildcards in user input cannot expand into a
        -- DoS-shaped ILIKE pattern. Client also calls sanitizePostgrestLike;
        -- this is defense in depth so the guarantee lives in the DB.
        ELSE replace(replace(replace(p_keyword, '\', '\\'), '%', '\%'), '_', '\_')
      END AS kw
  )
  SELECT e.*
  FROM public.events e, escaped_keyword
  WHERE e.status = p_status
    AND (p_city_id IS NULL OR e.city_id = p_city_id)
    AND (p_date_from IS NULL OR e.start_datetime >= p_date_from)
    AND (p_date_to IS NULL OR e.start_datetime <= p_date_to)
    AND (p_is_free IS NULL OR e.is_free = p_is_free)
    AND (p_is_featured IS NULL OR e.is_featured = p_is_featured)
    AND (p_age_min IS NULL OR COALESCE(e.age_max, 99) >= p_age_min)
    AND (p_age_max IS NULL OR COALESCE(e.age_min, 0) <= p_age_max)
    AND (
      escaped_keyword.kw IS NULL
      OR e.title ILIKE '%' || escaped_keyword.kw || '%' ESCAPE '\'
      OR e.description ILIKE '%' || escaped_keyword.kw || '%' ESCAPE '\'
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
  ORDER BY e.start_datetime ASC
  LIMIT p_limit OFFSET p_offset;
$$;

ALTER FUNCTION public.search_events(uuid, timestamp with time zone, timestamp with time zone, integer, integer, boolean, boolean, text[], text, text, integer, integer) OWNER TO postgres;

-- Restore baseline grants for search_events (baseline:6595-6597).
GRANT ALL ON FUNCTION public.search_events(uuid, timestamp with time zone, timestamp with time zone, integer, integer, boolean, boolean, text[], text, text, integer, integer)
  TO anon, authenticated, service_role;

-- ===========================================================================
-- 5. Drop the 10 additive indexes introduced by this migration (net-new).
--    None are present in baseline (grep: 0 matches each) -> inverse is DROP.
--    NOTE: events_published_feed_idx and events_published_local_date_city_idx are
--    also created by migration 017000; if 017000 is still applied, its own
--    *_down.sql owns those names. Dropping here is safe because 001000 created
--    them first; a full rollback runs newest-first so 017000_down already ran.
-- ===========================================================================
DROP INDEX IF EXISTS public.admin_audit_log_target_idx;
DROP INDEX IF EXISTS public.event_sources_active_last_scraped_idx;
DROP INDEX IF EXISTS public.source_runs_source_error_started_idx;
DROP INDEX IF EXISTS public.source_runs_started_at_idx;
DROP INDEX IF EXISTS public.source_scrape_queue_source_id_idx;
DROP INDEX IF EXISTS public.event_tag_queue_event_id_idx;
DROP INDEX IF EXISTS public.events_published_local_date_city_idx;
DROP INDEX IF EXISTS public.events_admin_status_created_idx;
DROP INDEX IF EXISTS public.events_admin_created_idx;
DROP INDEX IF EXISTS public.events_published_feed_idx;

-- ===========================================================================
-- 6. Re-grant function privileges the migration REVOKEd (reversible grants).
-- ===========================================================================

-- update_event_search_vector(): UP revoked from PUBLIC/anon/authenticated.
-- Restore baseline grants (baseline:6606-6608).
GRANT ALL ON FUNCTION public.update_event_search_vector() TO anon, authenticated, service_role;

-- ALTER DEFAULT PRIVILEGES: UP revoked the default function grants for anon and
-- authenticated. Restore baseline default grants (baseline:6867-6868).
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT ALL ON FUNCTIONS TO authenticated;

-- ===========================================================================
-- 7. Revert the 28 admin RLS policies from the perf-wrapped form
--    USING ((SELECT private.is_admin())) back to the bare baseline form
--    USING (private.is_admin()). Prior (bare) exprs verbatim from
--    20260601000000_schema_baseline.sql:5383-5499. Each ALTER below restores
--    exactly the USING / WITH CHECK clauses the UP migration touched (and only
--    those — the UP did not touch the user_access or llm-review policies).
-- ===========================================================================

-- 7a. DELETE policies (USING only).
ALTER POLICY "Admins can delete cities" ON public.cities
  USING (private.is_admin());
ALTER POLICY "Admins can delete event tags" ON public.event_tags
  USING (private.is_admin());
ALTER POLICY "Admins can delete events" ON public.events
  USING (private.is_admin());
ALTER POLICY "Admins can delete sources" ON public.event_sources
  USING (private.is_admin());
ALTER POLICY "Admins can delete tags" ON public.tags
  USING (private.is_admin());

-- 7b. INSERT policies (WITH CHECK only).
ALTER POLICY "Admins can insert audit log" ON public.admin_audit_log
  WITH CHECK (private.is_admin());
ALTER POLICY "Admins can insert cities" ON public.cities
  WITH CHECK (private.is_admin());
ALTER POLICY "Admins can insert event tags" ON public.event_tags
  WITH CHECK (private.is_admin());
ALTER POLICY "Admins can insert events" ON public.events
  WITH CHECK (private.is_admin());
ALTER POLICY "Admins can insert source runs" ON public.source_runs
  WITH CHECK (private.is_admin());
ALTER POLICY "Admins can insert sources" ON public.event_sources
  WITH CHECK (private.is_admin());
ALTER POLICY "Admins can insert tags" ON public.tags
  WITH CHECK (private.is_admin());

-- 7c. Combined manage policy (USING + WITH CHECK).
ALTER POLICY "Admins can manage invite codes" ON public.invite_codes
  USING (private.is_admin())
  WITH CHECK (private.is_admin());

-- 7d. READ / SELECT policies (USING only).
ALTER POLICY "Admins can read AI traces" ON public.event_ai_traces
  USING (private.is_admin());
ALTER POLICY "Admins can read audit log" ON public.admin_audit_log
  USING (private.is_admin());
ALTER POLICY "Admins can read invite redemption attempts" ON public.invite_redemption_attempts
  USING (private.is_admin());
ALTER POLICY "Admins can read invite request attempts" ON public.invite_request_attempts
  USING (private.is_admin());
ALTER POLICY "Admins can read invite requests" ON public.invite_requests
  USING (private.is_admin());
ALTER POLICY "Admins can read source extraction traces" ON public.source_extraction_traces
  USING (private.is_admin());
ALTER POLICY "Admins can read source scrape queue" ON public.source_scrape_queue
  USING (private.is_admin());
ALTER POLICY "Admins can read tag queue" ON public.event_tag_queue
  USING (private.is_admin());
ALTER POLICY "Admins can select source runs" ON public.source_runs
  USING (private.is_admin());
ALTER POLICY "Admins can select sources" ON public.event_sources
  USING (private.is_admin());

-- 7e. UPDATE policies (USING + WITH CHECK).
ALTER POLICY "Admins can update cities" ON public.cities
  USING (private.is_admin())
  WITH CHECK (private.is_admin());
ALTER POLICY "Admins can update event tags" ON public.event_tags
  USING (private.is_admin())
  WITH CHECK (private.is_admin());
ALTER POLICY "Admins can update events" ON public.events
  USING (private.is_admin())
  WITH CHECK (private.is_admin());
ALTER POLICY "Admins can update sources" ON public.event_sources
  USING (private.is_admin())
  WITH CHECK (private.is_admin());
ALTER POLICY "Admins can update tags" ON public.tags
  USING (private.is_admin())
  WITH CHECK (private.is_admin());

COMMIT;

-- ===========================================================================
-- STOP / IRREVERSIBLE / REDUNDANT — intentionally NOT reverted
-- ===========================================================================
-- The following UP effects are deliberately left in place. Reverting them would
-- corrupt the squashed-baseline contract (baseline already contains their
-- end-state) and/or cause data loss. Each was confirmed by grepping
-- 20260601000000_schema_baseline.sql.
--
-- (A) REDUNDANT — baseline already contains these as final state; DO NOT DROP:
--   * Six CHECK constraints (events_age_range_chk, events_lat_lng_chk,
--     events_price_chk, user_profiles_child_age_chk,
--     invite_codes_used_count_max_chk, event_sources_scrape_interval_chk).
--     The UP adds them NOT VALID, but baseline already ADDs + VALIDATEs all six
--     (baseline:664-991). Dropping them here would remove constraints the
--     baseline guarantees. -> NOT dropped.
--   * private.cron_enabled table + its 4-label seed. UP uses
--     CREATE TABLE IF NOT EXISTS; baseline already references the table as
--     existing (baseline:498-499 ENABLE RLS guarded by to_regclass). Treated as
--     baseline-owned. -> NOT dropped (would be data loss + baseline corruption).
--   * public.log_railway_cron_run(text,text,int,int,text),
--     public.admin_railway_cron_run_history(text,int),
--     private.railway_cron_run_history(text,int): the UP CREATE OR REPLACEs the
--     two public wrappers, but baseline already defines all three with identical
--     signatures (baseline:3842, 3452, 2938) and identical grants
--     (baseline:6495-6497). The CREATE OR REPLACE is a no-op on a baseline DB.
--     -> NOT dropped (dropping baseline objects would corrupt baseline state).
--     The REVOKE/GRANT block the UP issues for public.log_railway_cron_run
--     (FROM PUBLIC/anon/authenticated, TO service_role) matches baseline grants,
--     so it is also a no-op -> nothing to revert.
--
-- (B) DATA — NOT reverted (would be data loss / not safely invertible):
--   * Reference-data seed upserts from 006700_reference_data.sql:
--       INSERT ... ON CONFLICT DO UPDATE into public.cities (2 rows),
--       public.tags (20 rows), public.event_sources (10 rows).
--     These are idempotent upserts of production reference rows. A rollback
--     cannot know whether each row pre-existed or what its prior column values
--     were (ON CONFLICT DO UPDATE overwrote name/color/url/notes/etc.).
--     DELETING them could orphan FKs (events.city_id, event_tags.tag_id,
--     source_runs.source_id) and destroy real data. -> intentionally left as-is.
--     If a true data rollback is required, restore cities/tags/event_sources
--     from a pre-001000 backup; this file will not attempt it.
--
-- (C) SAFE-but-noted:
--   * The search_events restore (section 4) reintroduces the pre-full-text
--     (ILIKE-only) ranking and drops the search_vector/ts_rank_cd path. This is
--     the correct single-step inverse of 001000 but is a user-visible search
--     behavior regression; only run if you truly intend to be at the
--     baseline+000001 schema point.
--   * The ALTER DEFAULT PRIVILEGES re-GRANT (section 6) restores broad default
--     EXECUTE grants to anon/authenticated for FUTURE functions in schema public
--     — i.e. it re-opens the posture the UP migration tightened. Intended, since
--     that tightening was an effect of this migration.
