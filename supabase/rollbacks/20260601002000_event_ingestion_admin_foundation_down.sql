-- Rollback for 20260601002000_event_ingestion_admin_foundation.sql
--
-- The UP migration is a bundle of 8 logical sections (internal "-- Source:"
-- headers read 20260601007000..20260601007500, a squash artifact; the migration
-- actually applies at timestamp 002000). This rollback reverses every effect in
-- reverse dependency order.
--
-- ENUMERATED UP EFFECTS AND CHOSEN INVERSE
-- ----------------------------------------
-- Section 007000 (bulk_import_scrape_events):
--   - CREATE OR REPLACE private.bulk_import_scrape_events(uuid,uuid,jsonb)
--       REPLACED. Prior body: 20260601000000_schema_baseline.sql:15-168
--       (single chained-CTE form, no TEMP TABLEs, no 'skipped' counter).
--       Inverse: CREATE OR REPLACE back to the baseline body (restored below).
--   - CREATE OR REPLACE public.bulk_import_scrape_events(uuid,uuid,jsonb) (wrapper)
--       INTRODUCED (no public overload in baseline/001000). Inverse: DROP.
--   - REVOKE/GRANT on both + COMMENT on public wrapper
--       Grants follow the dropped/restored objects; COMMENT dies with the DROP.
--
-- Section 007001 (cursor_events_rpcs):
--   - CREATE INDEX IF NOT EXISTS events_published_start_id_idx
--       INTRODUCED (absent in baseline/001000). Inverse: DROP INDEX.
--   - CREATE OR REPLACE public.events_enriched_v2(...9 args)   INTRODUCED -> DROP
--   - CREATE OR REPLACE public.search_events_v2(...14 args)    INTRODUCED -> DROP
--
-- Section 007100 (admin_events_enriched):
--   - CREATE OR REPLACE private.admin_events_enriched(text,uuid,boolean,text,timestamptz,uuid,int)
--       INTRODUCED -> DROP
--   - CREATE OR REPLACE public.admin_events_enriched(...same 7 args) (wrapper)
--       INTRODUCED -> DROP
--
-- Section 007101 (event_enrichment_backfill):
--   - private.list_events_needing_enrichment(int)   INTRODUCED -> DROP
--   - public.list_events_needing_enrichment(int)    INTRODUCED -> DROP (wrapper)
--   - private.update_event_enrichment(uuid,numeric,numeric,jsonb)  INTRODUCED -> DROP
--   - public.update_event_enrichment(uuid,numeric,numeric,jsonb)   INTRODUCED -> DROP (wrapper)
--   - INSERT 'cron-enrich-events' INTO private.cron_enabled (ON CONFLICT DO NOTHING)
--       SEED. Inverse: DELETE that label (002000 is the only migration that
--       seeds it; 001000 seeds the other 4). See cron_enabled NOTE below.
--   - CREATE OR REPLACE private.list_railway_cron_jobs()
--       REPLACED. 002000 body has 5 labels (adds 'cron-enrich-events'). Prior
--       (pre-002000) body = the fresh CREATE FUNCTION at
--       20260601001000_reference_security_and_cron.sql:644-688 (4 labels, no
--       cron-enrich-events; identical RETURNS TABLE shape). Inverse: CREATE OR
--       REPLACE back to the 4-label 001000 body (restored below).
--       (Cross-check: 20260601009000_cron_review_events_allowlist_down.sql
--        independently cites 002000:851 as the 5-label body — consistent.)
--
-- Section 007200 (revoke_default_public_function_grants):
--   - REVOKE ALL/EXECUTE public.admin_set_cron_enabled(text,boolean) FROM PUBLIC, anon
--       NO-OP inverse. 001000:633-634 already revoked PUBLIC/anon and granted
--       only authenticated. The 002000 REVOKE is belt-and-suspenders and changed
--       no effective ACL, so there is nothing to "re-grant". Re-granting to
--       PUBLIC/anon would be WRONG (they were never grantees). Intentionally omitted.
--   - ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC
--       *** STOP / NOT AUTO-REVERSED *** see header STOP section below.
--
-- Section 007300 (tighten_private_schema_usage):
--   - GRANT USAGE ON SCHEMA private TO anon, authenticated, service_role
--       Idempotent re-grant (no-op; USAGE already granted by 002200/005600 per the
--       UP comment). NO inverse: revoking USAGE here would break the schema for
--       roles that legitimately hold it from earlier migrations. Intentionally omitted.
--
-- Section 007400 (admin_db_health):
--   - private.admin_db_health_snapshot()   INTRODUCED -> DROP
--   - public.admin_db_health_snapshot()    INTRODUCED -> DROP (wrapper)
--
-- Section 007500 (trace_retention):
--   - CREATE OR REPLACE private.run_daily_maintenance() RETURNS jsonb
--       REPLACED. 002000 body adds DELETEs for public.event_ai_traces and
--       public.source_extraction_traces (90d). Prior body:
--       20260601000000_schema_baseline.sql:3260-3295 (prunes only event_tag_queue,
--       invite_request_attempts, invite_redemption_attempts, recommendation_signals).
--       001000 did NOT touch this function (verified). Inverse: CREATE OR REPLACE
--       back to the baseline body + restore its COMMENT (restored below).
--       NOTE: 002000 only touched private.run_daily_maintenance; the public.*
--       wrapper is untouched and its () RETURNS jsonb signature is unchanged, so
--       the wrapper keeps working after this restore.
--
-- GRANTS POLICY: For all three CREATE-OR-REPLACE restores below (bulk_import,
-- list_railway_cron_jobs, run_daily_maintenance) the functions pre-existed 002000
-- and CREATE OR REPLACE preserves existing grants. This rollback therefore emits
-- NO GRANT/REVOKE for them (matching the asymmetry note in
-- 20260601009000_cron_review_events_allowlist_down.sql). SECURITY DEFINER,
-- SET search_path, and the is_admin() guard are all reproduced in the bodies.
--
-- ============================================================================
-- STOP / IRREVERSIBLE ITEMS (do NOT auto-apply; operator decision required)
-- ============================================================================
-- (A) ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC
--     This is NOT reversed automatically. Reasons:
--       1. It is a SECURITY-LOOSENING change to re-grant default EXECUTE to PUBLIC
--          for ALL future public functions — re-introducing exactly the broad
--          surface the UP migration deliberately closed.
--       2. ALTER DEFAULT PRIVILEGES is scoped to the role that ran it (FOR ROLE
--          <current_user>). A blind re-grant could target the wrong role / not
--          actually invert the original, depending on who applied the migration.
--       3. baseline does not contain a matching default-privileges grant to mirror,
--          so there is no verbatim prior state to restore.
--     If you truly must restore the pre-002000 default ACL, do so manually and
--     deliberately, e.g. (review the role first!):
--       -- ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO PUBLIC;
--     Leaving it in place is the safe default and does not affect any object
--     created by 002000 (those got explicit grants).
--
-- (B) No data is destroyed by this rollback. The dropped functions are
--     stateless RPCs/wrappers; the dropped index is derivable; the deleted
--     cron_enabled seed row only changes a default-true toggle (see NOTE).
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Drop INTRODUCED public wrappers first (they depend on private bodies).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.admin_db_health_snapshot();
DROP FUNCTION IF EXISTS public.update_event_enrichment(uuid, numeric, numeric, jsonb);
DROP FUNCTION IF EXISTS public.list_events_needing_enrichment(int);
DROP FUNCTION IF EXISTS public.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int);
DROP FUNCTION IF EXISTS public.bulk_import_scrape_events(uuid, uuid, jsonb);

-- ---------------------------------------------------------------------------
-- 2. Drop INTRODUCED private bodies behind those wrappers.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS private.admin_db_health_snapshot();
DROP FUNCTION IF EXISTS private.update_event_enrichment(uuid, numeric, numeric, jsonb);
DROP FUNCTION IF EXISTS private.list_events_needing_enrichment(int);
DROP FUNCTION IF EXISTS private.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int);

-- ---------------------------------------------------------------------------
-- 3. Drop INTRODUCED standalone enriched RPCs + the keyset index.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.search_events_v2(uuid, timestamptz, timestamptz, integer, integer, boolean, boolean, text[], text, text, integer, integer, timestamptz, uuid);
DROP FUNCTION IF EXISTS public.events_enriched_v2(uuid, text, uuid, uuid[], timestamptz, timestamptz, timestamptz, uuid, int);
DROP INDEX IF EXISTS public.events_published_start_id_idx;

-- ---------------------------------------------------------------------------
-- 4. Remove the seeded cron label (inverse of the UP INSERT ... ON CONFLICT
--    DO NOTHING). See cron_enabled NOTE: pre-002000 there was no
--    'cron-enrich-events' row, so list_railway_cron_jobs() reported enabled=true
--    for it via the COALESCE(..., true) default. Deleting the row restores that
--    exact prior behavior. If an admin has since toggled it to enabled=false,
--    that state is discarded on rollback — correct, since the row did not exist
--    before 002000.
-- ---------------------------------------------------------------------------
DELETE FROM private.cron_enabled WHERE label = 'cron-enrich-events';

-- ---------------------------------------------------------------------------
-- 5. Restore REPLACED private.list_railway_cron_jobs() to its pre-002000 body.
--    Verbatim from 20260601001000_reference_security_and_cron.sql:644-688
--    (the fresh CREATE FUNCTION; 4 labels, no 'cron-enrich-events').
--    RETURNS TABLE shape is identical to the 002000 body, so CREATE OR REPLACE
--    is sufficient (no DROP of the admin_list_railway_cron_jobs wrapper needed).
--    No GRANT/REVOKE emitted — see GRANTS POLICY above.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 6. Restore REPLACED private.bulk_import_scrape_events(uuid,uuid,jsonb) to its
--    pre-002000 body. Verbatim from 20260601000000_schema_baseline.sql:15-168
--    (single chained-CTE form; 'skipped' is hardcoded 0). Signature unchanged.
--    No GRANT/REVOKE emitted — see GRANTS POLICY above.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.bulk_import_scrape_events(p_run_id uuid, p_source_id uuid, p_events jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_auto_approve boolean;
  v_status       text;
  v_imported     int := 0;
  v_updated      int := 0;
  v_enqueued     int := 0;
BEGIN
  SELECT auto_approve INTO v_auto_approve
  FROM public.event_sources WHERE id = p_source_id;

  IF v_auto_approve IS NULL THEN
    RAISE EXCEPTION 'source not found: %', p_source_id USING ERRCODE = 'P0002';
  END IF;

  v_status := CASE WHEN v_auto_approve THEN 'published' ELSE 'draft' END;

  -- Single chained data-modifying WITH so we don't rely on TEMP TABLEs.
  -- TEMP TABLEs work at runtime but Postgres static analysis (db lint)
  -- can't see forward-referenced TEMP TABLEs across separate statements,
  -- producing noisy "relation does not exist" errors. CTE form is one
  -- statement, lint-clean, and identical semantics.
  --
  -- Data-modifying-CTE isolation in Postgres: each CTE sees the snapshot
  -- of target tables taken at statement start. `update_targets` therefore
  -- cannot see rows that `inserted` writes inside the same statement —
  -- which is exactly what we want, because every "update" row is a row
  -- that already existed before this RPC ran. The only overlap case
  -- (insert-that-fell-through ON CONFLICT) means a concurrent transaction
  -- inserted before us; that row IS visible in the snapshot.
  WITH inputs AS (
    SELECT
      (idx - 1)::int AS ord,
      (elem->>'title')::text                         AS title,
      (elem->>'description')::text                   AS description,
      (elem->>'start_datetime')::timestamptz         AS start_datetime,
      NULLIF(elem->>'end_datetime', '')::timestamptz AS end_datetime,
      (elem->>'timezone')::text                      AS timezone,
      (elem->>'venue_name')::text                    AS venue_name,
      (elem->>'address')::text                       AS address,
      NULLIF(elem->>'city_id', '')::uuid             AS city_id,
      NULLIF(elem->>'source_url', '')::text          AS source_url,
      (elem->>'source_name')::text                   AS source_name,
      COALESCE(elem->'images', '[]'::jsonb)          AS images,
      NULLIF(elem->>'price', '')::numeric            AS price,
      COALESCE((elem->>'is_free')::boolean, false)   AS is_free,
      NULLIF(elem->>'is_outdoor', '')::boolean       AS is_outdoor,
      NULLIF(elem->>'latitude', '')::numeric         AS latitude,
      NULLIF(elem->>'longitude', '')::numeric        AS longitude
    FROM jsonb_array_elements(p_events) WITH ORDINALITY AS j(elem, idx)
  ),
  classified AS (
    SELECT
      i.*,
      su.id AS source_url_match,
      CASE WHEN su.id IS NOT NULL THEN 'update' ELSE 'insert' END AS decision
    FROM inputs i
    LEFT JOIN LATERAL (
      SELECT e.id FROM public.events e
      WHERE e.source_id = p_source_id
        AND e.source_url IS NOT NULL
        AND e.source_url = i.source_url
      LIMIT 1
    ) su ON i.source_url IS NOT NULL
  ),
  inserted AS (
    INSERT INTO public.events (
      title, description, start_datetime, end_datetime, timezone,
      venue_name, address, city_id, latitude, longitude,
      price, is_free, is_outdoor,
      source_url, source_name, source_id,
      images, status
    )
    SELECT
      c.title, c.description, c.start_datetime, c.end_datetime, c.timezone,
      c.venue_name, c.address, c.city_id, c.latitude, c.longitude,
      c.price, c.is_free, c.is_outdoor,
      c.source_url, c.source_name, p_source_id,
      c.images, v_status
    FROM classified c
    WHERE c.decision = 'insert'
    ON CONFLICT (source_id, source_url)
      WHERE source_url IS NOT NULL
      DO NOTHING
    RETURNING id, source_url
  ),
  update_targets AS (
    SELECT c.*, e.id AS event_id, e.admin_locked_fields
    FROM classified c
    JOIN public.events e
      ON e.source_id = p_source_id
     AND e.source_url IS NOT NULL
     AND e.source_url = c.source_url
    WHERE c.decision = 'update'
       OR (
         c.decision = 'insert'
         AND c.source_url IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM inserted i WHERE i.source_url = c.source_url)
       )
  ),
  updated AS (
    UPDATE public.events e SET
      title          = CASE WHEN 'title'          = ANY(e.admin_locked_fields) THEN e.title          ELSE t.title          END,
      description    = CASE WHEN 'description'    = ANY(e.admin_locked_fields) THEN e.description    ELSE t.description    END,
      start_datetime = CASE WHEN 'start_datetime' = ANY(e.admin_locked_fields) THEN e.start_datetime ELSE t.start_datetime END,
      end_datetime   = CASE WHEN 'end_datetime'   = ANY(e.admin_locked_fields) THEN e.end_datetime   ELSE t.end_datetime   END,
      timezone       = CASE WHEN 'timezone'       = ANY(e.admin_locked_fields) THEN e.timezone       ELSE t.timezone       END,
      venue_name     = CASE WHEN 'venue_name'     = ANY(e.admin_locked_fields) THEN e.venue_name     ELSE t.venue_name     END,
      address        = CASE WHEN 'address'        = ANY(e.admin_locked_fields) THEN e.address        ELSE t.address        END,
      city_id        = CASE WHEN 'city_id'        = ANY(e.admin_locked_fields) THEN e.city_id        ELSE t.city_id        END,
      source_url     = CASE WHEN 'source_url'     = ANY(e.admin_locked_fields) THEN e.source_url     ELSE t.source_url     END,
      source_name    = CASE WHEN 'source_name'    = ANY(e.admin_locked_fields) THEN e.source_name    ELSE t.source_name    END,
      source_id      = CASE WHEN 'source_id'      = ANY(e.admin_locked_fields) THEN e.source_id      ELSE p_source_id      END,
      images         = CASE WHEN 'images'         = ANY(e.admin_locked_fields) THEN e.images         ELSE t.images         END,
      price          = CASE WHEN 'price'          = ANY(e.admin_locked_fields) THEN e.price          ELSE t.price          END,
      is_free        = CASE WHEN 'is_free'        = ANY(e.admin_locked_fields) THEN e.is_free        ELSE t.is_free        END,
      is_outdoor     = CASE WHEN 'is_outdoor'     = ANY(e.admin_locked_fields) THEN e.is_outdoor     ELSE t.is_outdoor     END,
      updated_at     = now()
    FROM update_targets t
    WHERE e.id = t.event_id
    RETURNING e.id
  ),
  all_imported AS (
    SELECT id FROM inserted
    UNION ALL
    SELECT event_id AS id FROM update_targets
  ),
  enqueued AS (
    INSERT INTO public.event_tag_queue (event_id, source_run_id, trigger_type)
    SELECT id, p_run_id, 'import' FROM all_imported
    ON CONFLICT (event_id) WHERE status IN ('pending', 'processing')
      DO NOTHING
    RETURNING id
  )
  SELECT
    (SELECT COUNT(*) FROM inserted),
    (SELECT COUNT(*) FROM updated),
    (SELECT COUNT(*) FROM enqueued)
  INTO v_imported, v_updated, v_enqueued;

  RETURN jsonb_build_object(
    'imported', v_imported,
    'updated',  v_updated,
    'skipped',  0,
    'enqueued', v_enqueued
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 7. Restore REPLACED private.run_daily_maintenance() to its pre-002000 body.
--    Verbatim from 20260601000000_schema_baseline.sql:3260-3301 (prunes only
--    event_tag_queue, invite_request_attempts, invite_redemption_attempts,
--    recommendation_signals — NOT event_ai_traces / source_extraction_traces).
--    Signature () RETURNS jsonb unchanged, so the public wrapper still resolves.
--    No GRANT/REVOKE emitted — see GRANTS POLICY above. COMMENT restored to match.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "private"."run_daily_maintenance"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_event_tag_pruned     int;
  v_invite_request_pruned int;
  v_invite_redemption_pruned int;
  v_rec_pruned           int;
BEGIN
  DELETE FROM public.event_tag_queue
  WHERE (status = 'dead'   AND finished_at < now() - interval '30 days')
     OR (status = 'failed' AND finished_at < now() - interval '7 days');
  GET DIAGNOSTICS v_event_tag_pruned = ROW_COUNT;

  DELETE FROM public.invite_request_attempts
  WHERE attempted_at < now() - interval '30 days';
  GET DIAGNOSTICS v_invite_request_pruned = ROW_COUNT;

  DELETE FROM public.invite_redemption_attempts
  WHERE attempted_at < now() - interval '30 days';
  GET DIAGNOSTICS v_invite_redemption_pruned = ROW_COUNT;

  DELETE FROM public.recommendation_signals
  WHERE created_at < now() - interval '90 days';
  GET DIAGNOSTICS v_rec_pruned = ROW_COUNT;

  RETURN jsonb_build_object(
    'event_tag_queue_pruned',          v_event_tag_pruned,
    'invite_request_attempts_pruned',  v_invite_request_pruned,
    'invite_redemption_attempts_pruned', v_invite_redemption_pruned,
    'recommendation_signals_pruned',   v_rec_pruned,
    'ran_at',                          now()
  );
END;
$$;

COMMENT ON FUNCTION "private"."run_daily_maintenance"() IS 'Daily prune: event_tag_queue dead/failed, invite_request_attempts, invite_redemption_attempts, recommendation_signals. Invoked by the cron-db-maintenance Railway service via the db-maintenance edge function.';

COMMIT;

-- ============================================================================
-- VERIFY CHECKLIST (run manually; NOT part of this transaction)
-- ============================================================================
-- BEFORE rollback (expected state after 002000 applied):
--   -- 5-label cron list incl. cron-enrich-events:
--   SELECT array_agg(DISTINCT regexp_replace(pg_get_functiondef(p.oid), '.*', '', 'g'))
--     FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--    WHERE n.nspname='private' AND p.proname='list_railway_cron_jobs';
--   -- simpler: confirm the literal label appears in the body:
--   SELECT position('cron-enrich-events' IN pg_get_functiondef('private.list_railway_cron_jobs()'::regprocedure)) > 0;  -- expect t
--   SELECT count(*) FROM private.cron_enabled WHERE label='cron-enrich-events';                                         -- expect 1
--   -- run_daily_maintenance still prunes traces:
--   SELECT position('event_ai_traces' IN pg_get_functiondef('private.run_daily_maintenance()'::regprocedure)) > 0;     -- expect t
--   -- introduced objects exist:
--   SELECT to_regprocedure('public.events_enriched_v2(uuid,text,uuid,uuid[],timestamptz,timestamptz,timestamptz,uuid,int)') IS NOT NULL;  -- t
--   SELECT to_regprocedure('public.search_events_v2(uuid,timestamptz,timestamptz,integer,integer,boolean,boolean,text[],text,text,integer,integer,timestamptz,uuid)') IS NOT NULL; -- t
--   SELECT to_regprocedure('private.admin_events_enriched(text,uuid,boolean,text,timestamptz,uuid,int)') IS NOT NULL;   -- t
--   SELECT to_regprocedure('public.admin_events_enriched(text,uuid,boolean,text,timestamptz,uuid,int)') IS NOT NULL;    -- t
--   SELECT to_regprocedure('private.list_events_needing_enrichment(int)') IS NOT NULL;                                  -- t
--   SELECT to_regprocedure('public.list_events_needing_enrichment(int)') IS NOT NULL;                                   -- t
--   SELECT to_regprocedure('private.update_event_enrichment(uuid,numeric,numeric,jsonb)') IS NOT NULL;                  -- t
--   SELECT to_regprocedure('public.update_event_enrichment(uuid,numeric,numeric,jsonb)') IS NOT NULL;                   -- t
--   SELECT to_regprocedure('private.admin_db_health_snapshot()') IS NOT NULL;                                           -- t
--   SELECT to_regprocedure('public.admin_db_health_snapshot()') IS NOT NULL;                                            -- t
--   SELECT to_regprocedure('public.bulk_import_scrape_events(uuid,uuid,jsonb)') IS NOT NULL;                            -- t
--   SELECT to_regclass('public.events_published_start_id_idx') IS NOT NULL;                                             -- t
--
-- AFTER rollback (expected state):
--   SELECT position('cron-enrich-events' IN pg_get_functiondef('private.list_railway_cron_jobs()'::regprocedure)) > 0;  -- expect f
--   SELECT count(*) FROM private.cron_enabled WHERE label='cron-enrich-events';                                         -- expect 0
--   SELECT position('event_ai_traces' IN pg_get_functiondef('private.run_daily_maintenance()'::regprocedure)) > 0;     -- expect f
--   SELECT position('source_extraction_traces' IN pg_get_functiondef('private.run_daily_maintenance()'::regprocedure)) > 0; -- expect f
--   -- introduced objects gone:
--   SELECT to_regprocedure('public.events_enriched_v2(uuid,text,uuid,uuid[],timestamptz,timestamptz,timestamptz,uuid,int)') IS NULL;  -- t
--   SELECT to_regprocedure('public.search_events_v2(uuid,timestamptz,timestamptz,integer,integer,boolean,boolean,text[],text,text,integer,integer,timestamptz,uuid)') IS NULL; -- t
--   SELECT to_regprocedure('private.admin_events_enriched(text,uuid,boolean,text,timestamptz,uuid,int)') IS NULL;   -- t
--   SELECT to_regprocedure('public.admin_events_enriched(text,uuid,boolean,text,timestamptz,uuid,int)') IS NULL;    -- t
--   SELECT to_regprocedure('private.list_events_needing_enrichment(int)') IS NULL;                                  -- t
--   SELECT to_regprocedure('public.list_events_needing_enrichment(int)') IS NULL;                                   -- t
--   SELECT to_regprocedure('private.update_event_enrichment(uuid,numeric,numeric,jsonb)') IS NULL;                  -- t
--   SELECT to_regprocedure('public.update_event_enrichment(uuid,numeric,numeric,jsonb)') IS NULL;                   -- t
--   SELECT to_regprocedure('private.admin_db_health_snapshot()') IS NULL;                                           -- t
--   SELECT to_regprocedure('public.admin_db_health_snapshot()') IS NULL;                                            -- t
--   SELECT to_regprocedure('public.bulk_import_scrape_events(uuid,uuid,jsonb)') IS NULL;                            -- t
--   SELECT to_regclass('public.events_published_start_id_idx') IS NULL;                                             -- t
--   -- restored bodies still exist (replaced, not dropped):
--   SELECT to_regprocedure('private.bulk_import_scrape_events(uuid,uuid,jsonb)') IS NOT NULL;                        -- t
--   SELECT to_regprocedure('private.list_railway_cron_jobs()') IS NOT NULL;                                          -- t
--   SELECT to_regprocedure('private.run_daily_maintenance()') IS NOT NULL;                                           -- t
-- ============================================================================
