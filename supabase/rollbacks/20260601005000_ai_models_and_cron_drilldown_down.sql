-- Rollback for 20260601005000_ai_models_and_cron_drilldown.sql
--
-- The UP migration is a concatenation of 5 source files:
--   009500 ai_model_config             — NEW tables approved_ai_models, ai_feature_config;
--                                         NEW fns upsert_ai_feature_config (private+public),
--                                         get_approved_ai_models; NEW col event_ai_traces.prompt_version
--   009501 revoke_private_upsert        — REVOKE only (no schema)
--   009502 repair_ai_model_config       — idempotent re-run of 009500 (same end-state)
--   009503 add_gpt5_models              — seed INSERT/UPDATE rows into approved_ai_models / ai_feature_config
--   009504 cron_run_log_drilldown       — NEW col private.railway_cron_runs.run_key + unique index;
--                                         NEW table private.cron_run_log_entries;
--                                         NEW fns log_cron_run_event (private+public),
--                                         railway_cron_run_detail / admin_railway_cron_run_detail;
--                                         REPLACES log_railway_cron_run 5-param -> 7-param (both schemas)
--
-- This rollback returns the schema to its state immediately AFTER migration
-- 20260601004000 (i.e. before 005000). Every object below was INTRODUCED by 005000
-- and is therefore dropped, EXCEPT log_railway_cron_run, which 005000 REPLACED
-- (dropped the 5-param overload, created a 7-param overload) — that one is restored
-- to its prior 5-param body.
--
-- PRIOR-DEF SOURCES (for the two restored functions):
--   private.log_railway_cron_run(text,text,integer,integer,text)
--     -> 20260601000000_schema_baseline.sql lines 2797-2806 (verbatim body below).
--        001000 did NOT redefine the private overload; baseline body is the prior def.
--   public.log_railway_cron_run(text,text,integer,integer,text)
--     -> 20260601000000_schema_baseline.sql lines 3842-3850 (verbatim body below).
--        Prior GRANT state is per 20260601001000_reference_security_and_cron.sql
--        lines 238-247: both overloads REVOKE'd from PUBLIC/anon/authenticated,
--        GRANT'd to service_role only. (Baseline 6247/6495-6497 was superseded by 001000.)
--
-- Objects DROPPED (introduced by 005000, no earlier definition — confirmed by grep of
-- baseline + 001000..004000): approved_ai_models, ai_feature_config,
-- private/public.upsert_ai_feature_config, public.get_approved_ai_models,
-- event_ai_traces.prompt_version, private.railway_cron_runs.run_key (+ unique index),
-- private.cron_run_log_entries (+ indexes + seq grants), private/public.log_cron_run_event,
-- private.railway_cron_run_detail, public.admin_railway_cron_run_detail, and the
-- 7-param log_railway_cron_run overloads.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- ORDERING / SAFETY HAZARDS — READ BEFORE RUNNING
-- ─────────────────────────────────────────────────────────────────────────────
-- 1. FORWARD-DEPENDENCY HAZARD (run order matters):
--    Later migrations (>005000) build directly on objects 005000 created:
--      - 006000 (009701/parent-tips): adds indexes on ai_feature_config, REPLACES the
--        ai_feature_config_feature_check CHECK to allow 'parent-tips', CREATE OR REPLACE
--        private.upsert_ai_feature_config (3-arg, same signature), and depends on
--        approved_ai_models / ai_feature_config.
--      - 023000: re-GRANTs private.upsert_ai_feature_config to authenticated.
--    This rollback ONLY undoes 005000 and assumes 005000 is the most-recently-applied
--    migration. If 006000+ are still applied, DROPPING approved_ai_models /
--    ai_feature_config / upsert_ai_feature_config here will fail (dependent objects) or
--    silently destroy 006000's work. Roll back the LATER migrations FIRST, in reverse
--    timestamp order, before running this file. Do NOT run standalone on a DB past 005000.
--
-- 2. DATA-LOSS HAZARD (acceptable for a true 005->004 rollback, but be aware):
--    DROP TABLE approved_ai_models / ai_feature_config / cron_run_log_entries and
--    DROP COLUMN run_key / prompt_version are DESTRUCTIVE — all rows / column values are
--    lost. There is no pre-005000 state to preserve for these (they did not exist), so
--    this is the correct inverse, but it is not idempotent-data-safe.
--
-- 3. CHECK-FUNCTION-BODIES / overload ambiguity:
--    We DROP the 7-param log_railway_cron_run overloads first, then recreate the 5-param
--    overloads. The 5-param public wrapper body references the 5-param private overload;
--    after the 7-param drops there is no ambiguity, so no special check_function_bodies
--    handling is required.

BEGIN;

-- ╔═══════════════════════════════════════════════════════════════════════════╗
-- ║ PART A — Reverse 009504 (cron_run_log_drilldown), in reverse dep order      ║
-- ╚═══════════════════════════════════════════════════════════════════════════╝

-- A1. Drop the public/private run-detail RPCs (depend on cron_run_log_entries +
--     railway_cron_runs). public wrapper first (depends on private).
DROP FUNCTION IF EXISTS public.admin_railway_cron_run_detail(bigint);
DROP FUNCTION IF EXISTS private.railway_cron_run_detail(bigint);

-- A2. Drop the 7-param log_railway_cron_run overloads introduced by 005000.
--     public wrapper first (depends on private), then private (depends on
--     log_cron_run_event + cron_run_log_entries).
DROP FUNCTION IF EXISTS public.log_railway_cron_run(text, text, integer, integer, text, uuid, text);
DROP FUNCTION IF EXISTS private.log_railway_cron_run(text, text, integer, integer, text, uuid, text);

-- A3. Restore the prior 5-param log_railway_cron_run overloads.
--     Bodies copied verbatim from 20260601000000_schema_baseline.sql.
--     private (lines 2797-2806):
CREATE OR REPLACE FUNCTION private.log_railway_cron_run(
  p_label text,
  p_status text,
  p_http_status integer DEFAULT NULL::integer,
  p_duration_s integer DEFAULT NULL::integer,
  p_body text DEFAULT NULL::text
) RETURNS void
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
AS $$
  INSERT INTO private.railway_cron_runs (label, status, http_status, duration_s, body)
  VALUES (p_label, p_status, p_http_status, p_duration_s, p_body);
$$;

ALTER FUNCTION private.log_railway_cron_run(text, text, integer, integer, text)
  OWNER TO postgres;

--     public (baseline lines 3842-3850):
CREATE OR REPLACE FUNCTION public.log_railway_cron_run(
  p_label text,
  p_status text,
  p_http_status integer DEFAULT NULL::integer,
  p_duration_s integer DEFAULT NULL::integer,
  p_body text DEFAULT NULL::text
) RETURNS void
  LANGUAGE sql
  SET search_path TO ''
AS $$
  SELECT private.log_railway_cron_run(p_label, p_status, p_http_status, p_duration_s, p_body);
$$;

ALTER FUNCTION public.log_railway_cron_run(text, text, integer, integer, text)
  OWNER TO postgres;

-- A4. Restore prior GRANT state for the 5-param overloads.
--     Per 20260601001000 lines 238-247: revoke broad, grant service_role only.
REVOKE ALL ON FUNCTION private.log_railway_cron_run(text, text, integer, integer, text)
  FROM PUBLIC, anon, authenticated;
GRANT ALL ON FUNCTION private.log_railway_cron_run(text, text, integer, integer, text)
  TO service_role;

REVOKE ALL ON FUNCTION public.log_railway_cron_run(text, text, integer, integer, text)
  FROM PUBLIC, anon, authenticated;
GRANT ALL ON FUNCTION public.log_railway_cron_run(text, text, integer, integer, text)
  TO service_role;

-- A5. Drop the log_cron_run_event RPCs introduced by 005000 (public wrapper first).
DROP FUNCTION IF EXISTS public.log_cron_run_event(uuid, text, text, text, text, jsonb, integer);
DROP FUNCTION IF EXISTS private.log_cron_run_event(uuid, text, text, text, text, jsonb, integer);

-- A6. Drop the cron_run_log_entries table (introduced by 005000).
--     Dropping the table removes its indexes, identity sequence, and RLS automatically.
DROP TABLE IF EXISTS private.cron_run_log_entries;

-- A7. Drop the run_key column + its unique index on railway_cron_runs (introduced by 005000).
--     DROP COLUMN ... CASCADE removes the unique index implicitly; drop index explicitly
--     first to be safe, then the column.
DROP INDEX IF EXISTS private.railway_cron_runs_run_key_key;
ALTER TABLE private.railway_cron_runs
  DROP COLUMN IF EXISTS run_key;

-- ╔═══════════════════════════════════════════════════════════════════════════╗
-- ║ PART B — Reverse 009503 (add_gpt5_models)                                   ║
-- ╚═══════════════════════════════════════════════════════════════════════════╝
-- No-op: 009503 only INSERTed/UPDATEd seed rows into approved_ai_models /
-- ai_feature_config. Those tables are dropped wholesale in PART C, so the seed
-- rows and is_enabled toggles vanish with them. Nothing to reverse here.

-- ╔═══════════════════════════════════════════════════════════════════════════╗
-- ║ PART C — Reverse 009502/009501/009500 (ai_model_config), reverse dep order  ║
-- ╚═══════════════════════════════════════════════════════════════════════════╝

-- C1. Drop the AI-config RPCs (no earlier definition — introduced by 005000).
--     public.upsert wrapper first (depends on private), then private, then the
--     standalone read fn.
DROP FUNCTION IF EXISTS public.upsert_ai_feature_config(text, text, bool);
DROP FUNCTION IF EXISTS private.upsert_ai_feature_config(text, text, bool);
DROP FUNCTION IF EXISTS public.get_approved_ai_models();

-- C2. Drop the prompt_version column on event_ai_traces (introduced by 005000;
--     baseline event_ai_traces def at line 4356 has no such column).
ALTER TABLE public.event_ai_traces
  DROP COLUMN IF EXISTS prompt_version;

-- C3. Drop the two new tables. ai_feature_config first — it has a FK
--     (model_id -> approved_ai_models.id), so it must go before approved_ai_models.
--     Dropping the tables removes their RLS policies, grants, and FK indexes.
DROP TABLE IF EXISTS public.ai_feature_config;
DROP TABLE IF EXISTS public.approved_ai_models;

COMMIT;
