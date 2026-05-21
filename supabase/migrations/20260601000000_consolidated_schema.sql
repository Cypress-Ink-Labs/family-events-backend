


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";






CREATE SCHEMA IF NOT EXISTS "private";


ALTER SCHEMA "private" OWNER TO "postgres";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "cube" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "earthdistance" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."event_tag_queue_status" AS ENUM (
    'pending',
    'processing',
    'failed',
    'dead',
    'succeeded'
);


ALTER TYPE "public"."event_tag_queue_status" OWNER TO "postgres";


CREATE TYPE "public"."invite_request_status" AS ENUM (
    'pending',
    'approved',
    'rejected'
);


ALTER TYPE "public"."invite_request_status" OWNER TO "postgres";


CREATE TYPE "public"."source_extraction_mode" AS ENUM (
    'deterministic',
    'llm',
    'deterministic_then_llm'
);


ALTER TYPE "public"."source_extraction_mode" OWNER TO "postgres";


CREATE TYPE "public"."source_scrape_queue_status" AS ENUM (
    'pending',
    'processing',
    'retrying',
    'succeeded',
    'dead'
);


ALTER TYPE "public"."source_scrape_queue_status" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."admin_approve_invite_request"("p_request_id" "uuid") RETURNS TABLE("request_id" "uuid", "code" "text", "invite_code_id" "uuid", "email" "text", "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_email       text;
  v_code        text;
  v_code_hash   text;
  v_id          uuid;
  v_caller      uuid;
  v_alphabet    constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_length      constant int  := 24;
  i             int;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  v_caller := auth.uid();

  -- Table alias keeps the column reference unambiguous against the
  -- RETURNS TABLE's implicit `email` local variable.
  SELECT r.email INTO v_email
  FROM public.invite_requests r
  WHERE r.id = p_request_id AND r.status = 'pending'
  FOR UPDATE;

  IF v_email IS NULL THEN
    RAISE EXCEPTION 'request not found or already reviewed' USING ERRCODE = 'P0002';
  END IF;

  v_code := '';
  FOR i IN 1..v_length LOOP
    v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
  END LOOP;

  v_code_hash := private.hash_invite_code(v_code);

  INSERT INTO public.invite_codes (code_hash, max_uses, expires_at, notes, created_by, created_at)
  VALUES (
    v_code_hash, 1, NULL,
    'Approved invite request: ' || v_email,
    v_caller, now()
  )
  RETURNING public.invite_codes.id INTO v_id;

  UPDATE public.invite_requests
  SET
    status         = 'approved',
    invite_code_id = v_id,
    reviewed_at    = now(),
    reviewed_by    = v_caller
  WHERE id = p_request_id;

  -- Email the requester their code. Async + swallowed so an email outage
  -- never blocks the admin's approve action.
  BEGIN
    PERFORM private.dispatch_email_notification(jsonb_build_object(
      'kind',  'request_approved',
      'email', v_email,
      'code',  v_code
    ));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Failed to dispatch approved invite email: %', SQLERRM;
  END;

  RETURN QUERY
  SELECT
    p_request_id,
    v_code,
    v_id,
    v_email,
    now()::timestamptz;
END;
$$;


ALTER FUNCTION "private"."admin_approve_invite_request"("p_request_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."admin_bulk_set_auto_approve"("enable" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  affected integer;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  UPDATE public.event_sources SET auto_approve = enable WHERE true;
  GET DIAGNOSTICS affected = ROW_COUNT;

  INSERT INTO public.admin_audit_log (admin_user_id, action, target_type, metadata)
  VALUES (
    auth.uid(),
    'bulk_set_auto_approve',
    'event_sources',
    jsonb_build_object('enable', enable, 'affected_count', affected)
  );
END;
$$;


ALTER FUNCTION "private"."admin_bulk_set_auto_approve"("enable" boolean) OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "start_datetime" timestamp with time zone NOT NULL,
    "end_datetime" timestamp with time zone,
    "timezone" "text" DEFAULT 'America/Chicago'::"text" NOT NULL,
    "venue_name" "text",
    "address" "text",
    "city_id" "uuid",
    "latitude" numeric(10,7),
    "longitude" numeric(10,7),
    "age_min" integer,
    "age_max" integer,
    "price" numeric(10,2),
    "is_free" boolean DEFAULT false NOT NULL,
    "source_url" "text",
    "source_name" "text",
    "source_id" "uuid",
    "images" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "ai_confidence" numeric(4,3) DEFAULT 0,
    "ai_tag_provider" "text",
    "recurrence_info" "jsonb",
    "is_featured" boolean DEFAULT false NOT NULL,
    "is_outdoor" boolean,
    "view_count" integer DEFAULT 0 NOT NULL,
    "search_vector" "tsvector",
    "admin_locked_fields" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "admin_last_edited_at" timestamp with time zone,
    "admin_last_edited_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "ai_tag_model" "text",
    "ai_tag_status" "text",
    CONSTRAINT "events_address_len_chk" CHECK ((("address" IS NULL) OR ("length"("address") <= 500))),
    CONSTRAINT "events_ai_tag_provider_check" CHECK ((("ai_tag_provider" IS NULL) OR ("ai_tag_provider" = ANY (ARRAY['openai'::"text", 'ollama'::"text", 'localai'::"text"])))),
    CONSTRAINT "events_ai_tag_status_check" CHECK ((("ai_tag_status" IS NULL) OR ("ai_tag_status" = ANY (ARRAY['success'::"text", 'fallback'::"text", 'error'::"text"])))),
    CONSTRAINT "events_description_len_chk" CHECK ((("description" IS NULL) OR ("length"("description") <= 10000))),
    CONSTRAINT "events_images_shape_chk" CHECK ((("jsonb_typeof"("images") = 'array'::"text") AND ("jsonb_array_length"("images") <= 20))),
    CONSTRAINT "events_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'published'::"text", 'rejected'::"text", 'archived'::"text"]))),
    CONSTRAINT "events_title_len_chk" CHECK (("length"("title") <= 500)),
    CONSTRAINT "events_venue_name_len_chk" CHECK ((("venue_name" IS NULL) OR ("length"("venue_name") <= 300)))
);

ALTER TABLE ONLY "public"."events" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."events" OWNER TO "postgres";


COMMENT ON COLUMN "public"."events"."ai_tag_model" IS 'Concrete model identifier (e.g. gpt-4o-mini, qwen3:1.7b, gemma4:e4b) used to generate ai_tag_provider classification. NULL when no AI tagging ran.';



COMMENT ON COLUMN "public"."events"."ai_tag_status" IS 'Outcome of the AI tagging pipeline. success=LLM produced classification; fallback=LLM unavailable or failed, keyword matcher used; error=tagging errored. NULL when no tagging has run.';



CREATE OR REPLACE FUNCTION "private"."admin_create_event"("p_patch" "jsonb", "p_tag_ids" "uuid"[] DEFAULT '{}'::"uuid"[]) RETURNS "public"."events"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
  created_row public.events%ROWTYPE;
  patch jsonb;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_EVENT_ADMIN_REQUIRED';
  END IF;

  patch := private.admin_validate_event_patch(COALESCE(p_patch, '{}'::jsonb));
  IF NOT patch ? 'title' OR NULLIF(btrim(patch->>'title'), '') IS NULL THEN
    RAISE EXCEPTION 'ADMIN_EVENT_TITLE_REQUIRED';
  END IF;
  IF NOT patch ? 'start_datetime' OR jsonb_typeof(patch->'start_datetime') = 'null' THEN
    RAISE EXCEPTION 'ADMIN_EVENT_TITLE_REQUIRED';
  END IF;

  INSERT INTO public.events (title, start_datetime, source_name)
  VALUES (patch->>'title', (patch->>'start_datetime')::timestamptz, 'Manual')
  RETURNING * INTO created_row;

  created_row := private.admin_update_event(created_row.id, patch, p_tag_ids, true);

  INSERT INTO public.admin_audit_log (admin_user_id, action, target_type, target_id, metadata)
  VALUES (
    auth.uid(),
    'event.create',
    'event',
    created_row.id,
    jsonb_build_object('patch', patch, 'tag_ids', to_jsonb(COALESCE(p_tag_ids, '{}'::uuid[])))
  );

  RETURN created_row;
END;
$$;


ALTER FUNCTION "private"."admin_create_event"("p_patch" "jsonb", "p_tag_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."admin_create_invite_code"("p_max_uses" integer DEFAULT 1, "p_expires_at" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_notes" "text" DEFAULT NULL::"text") RETURNS TABLE("id" "uuid", "code" "text", "max_uses" integer, "expires_at" timestamp with time zone, "notes" "text", "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_code       text;
  v_code_hash  text;
  v_id         uuid;
  v_caller     uuid;
  v_alphabet   constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';  -- no 0/1/I/O for legibility
  v_length     constant int  := 24;
  i            int;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_max_uses IS NULL OR p_max_uses < 1 THEN
    RAISE EXCEPTION 'max_uses must be >= 1' USING ERRCODE = '22023';
  END IF;

  -- Build a 24-char URL-safe code. 32 alphabet chars ^ 24 ≈ 2^120 entropy.
  v_code := '';
  FOR i IN 1..v_length LOOP
    v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
  END LOOP;

  v_code_hash := private.hash_invite_code(v_code);
  v_caller    := auth.uid();

  INSERT INTO public.invite_codes (code_hash, max_uses, expires_at, notes, created_by, created_at)
  VALUES (v_code_hash, p_max_uses, p_expires_at, p_notes, v_caller, now())
  RETURNING public.invite_codes.id INTO v_id;

  RETURN QUERY
  SELECT
    v_id,
    v_code,                -- visible to the caller exactly once
    p_max_uses,
    p_expires_at,
    p_notes,
    now()::timestamptz;
END;
$$;


ALTER FUNCTION "private"."admin_create_invite_code"("p_max_uses" integer, "p_expires_at" timestamp with time zone, "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."admin_cron_run_history"("p_job_name" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 50) RETURNS TABLE("runid" bigint, "jobname" "text", "status" "text", "return_message" "text", "start_time" timestamp with time zone, "end_time" timestamp with time zone, "duration_ms" numeric)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    d.runid,
    j.jobname,
    d.status,
    d.return_message,
    d.start_time,
    d.end_time,
    CASE
      WHEN d.end_time IS NOT NULL
      THEN ROUND(EXTRACT(EPOCH FROM (d.end_time - d.start_time)) * 1000)
      ELSE NULL
    END AS duration_ms
  FROM cron.job_run_details d
  JOIN cron.job j ON j.jobid = d.jobid
  WHERE (p_job_name IS NULL OR j.jobname = p_job_name)
  ORDER BY d.start_time DESC
  LIMIT GREATEST(COALESCE(p_limit, 50), 1);
END;
$$;


ALTER FUNCTION "private"."admin_cron_run_history"("p_job_name" "text", "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."admin_delete_rating"("p_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_deleted int;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  DELETE FROM public.ratings
  WHERE id = p_id;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted > 0;
END;
$$;


ALTER FUNCTION "private"."admin_delete_rating"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."admin_list_cron_jobs"() RETURNS TABLE("jobid" bigint, "jobname" "text", "schedule" "text", "command" "text", "active" boolean, "last_run_start" timestamp with time zone, "last_run_end" timestamp with time zone, "last_run_status" "text", "last_run_message" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    j.jobid,
    j.jobname,
    j.schedule,
    j.command,
    j.active,
    d.start_time,
    d.end_time,
    d.status,
    d.return_message
  FROM cron.job j
  LEFT JOIN LATERAL (
    SELECT jrd.start_time, jrd.end_time, jrd.status, jrd.return_message
    FROM cron.job_run_details jrd
    WHERE jrd.jobid = j.jobid
    ORDER BY jrd.start_time DESC
    LIMIT 1
  ) d ON true
  ORDER BY j.jobname;
END;
$$;


ALTER FUNCTION "private"."admin_list_cron_jobs"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."admin_reject_invite_request"("p_request_id" "uuid", "p_notes" "text" DEFAULT NULL::"text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_caller uuid;
  v_notes  text;
  v_email  text;
  v_rows   int;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  v_caller := auth.uid();
  v_notes := nullif(btrim(coalesce(p_notes, '')), '');
  IF v_notes IS NOT NULL AND length(v_notes) > 1000 THEN
    v_notes := substring(v_notes FROM 1 FOR 1000);
  END IF;

  -- Capture the requester email up-front so the dispatch can fire even though
  -- the row UPDATE flips its status; the column value itself doesn't change.
  SELECT r.email INTO v_email
  FROM public.invite_requests r
  WHERE r.id = p_request_id AND r.status = 'pending'
  FOR UPDATE;

  IF v_email IS NULL THEN
    RETURN false;
  END IF;

  UPDATE public.invite_requests
  SET
    status      = 'rejected',
    admin_notes = v_notes,
    reviewed_at = now(),
    reviewed_by = v_caller
  WHERE id = p_request_id;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RETURN false;
  END IF;

  -- Notify the requester. Async + swallowed so an email outage never blocks
  -- the admin's reject action — the DB transition already happened above.
  BEGIN
    PERFORM private.dispatch_email_notification(jsonb_build_object(
      'kind',  'request_rejected',
      'email', v_email
    ));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Failed to dispatch rejected invite email: %', SQLERRM;
  END;

  RETURN true;
END;
$$;


ALTER FUNCTION "private"."admin_reject_invite_request"("p_request_id" "uuid", "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."admin_retry_source_scrape_queue"("p_queue_id" bigint) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_source_id uuid;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT source_id INTO v_source_id
  FROM public.source_scrape_queue
  WHERE id = p_queue_id
    AND status = 'dead';

  IF v_source_id IS NULL THEN
    RETURN false;
  END IF;

  INSERT INTO public.source_scrape_queue (source_id, trigger_type)
  VALUES (v_source_id, 'retry')
  ON CONFLICT DO NOTHING;

  RETURN EXISTS (
    SELECT 1 FROM public.source_scrape_queue
    WHERE source_id = v_source_id
      AND status IN ('pending', 'processing', 'retrying')
  );
END;
$$;


ALTER FUNCTION "private"."admin_retry_source_scrape_queue"("p_queue_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."admin_retry_tag_queue"("p_event_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.event_tag_queue (event_id, trigger_type)
  VALUES (p_event_id, 'manual-review')
  ON CONFLICT DO NOTHING;  -- partial-unique index handles dedup

  -- Did we add a new active row? Either way, return whether at least one is now active.
  RETURN EXISTS (
    SELECT 1 FROM public.event_tag_queue
    WHERE event_id = p_event_id AND status IN ('pending','processing')
  );
END;
$$;


ALTER FUNCTION "private"."admin_retry_tag_queue"("p_event_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."admin_revoke_invite_code"("p_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_updated int;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  UPDATE public.invite_codes
  SET revoked_at = now()
  WHERE id = p_id
    AND revoked_at IS NULL;

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated > 0;
END;
$$;


ALTER FUNCTION "private"."admin_revoke_invite_code"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."admin_run_due_scrapes"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  PERFORM public.run_due_source_scrapes();
END;
$$;


ALTER FUNCTION "private"."admin_run_due_scrapes"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."admin_set_cron_schedule"("p_job_name" "text", "p_schedule" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_command text;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT command INTO v_command FROM cron.job WHERE jobname = p_job_name;

  IF v_command IS NULL THEN
    RAISE EXCEPTION 'cron job not found: %', p_job_name USING ERRCODE = 'P0002';
  END IF;

  PERFORM cron.schedule(p_job_name, p_schedule, v_command);
END;
$$;


ALTER FUNCTION "private"."admin_set_cron_schedule"("p_job_name" "text", "p_schedule" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."admin_toggle_cron_job"("p_job_name" "text", "p_active" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  UPDATE cron.job SET active = p_active WHERE jobname = p_job_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'cron job not found: %', p_job_name USING ERRCODE = 'P0002';
  END IF;
END;
$$;


ALTER FUNCTION "private"."admin_toggle_cron_job"("p_job_name" "text", "p_active" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."admin_unlock_event_fields"("p_event_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_EVENT_ADMIN_REQUIRED';
  END IF;

  UPDATE public.events
     SET admin_locked_fields = '{}',
         admin_last_edited_at = now(),
         admin_last_edited_by = auth.uid(),
         updated_at = now()
   WHERE id = p_event_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ADMIN_EVENT_NOT_FOUND';
  END IF;

  INSERT INTO public.admin_audit_log (admin_user_id, action, target_type, target_id, metadata)
  VALUES (
    auth.uid(),
    'event.fields.unlock',
    'event',
    p_event_id,
    jsonb_build_object('locked_fields_after', '[]'::jsonb)
  );

  RETURN true;
END;
$$;


ALTER FUNCTION "private"."admin_unlock_event_fields"("p_event_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."admin_update_event"("p_event_id" "uuid", "p_patch" "jsonb", "p_tag_ids" "uuid"[], "p_lock_edited_fields" boolean DEFAULT true) RETURNS "public"."events"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
  patch jsonb;
  before_row public.events%ROWTYPE;
  updated_row public.events%ROWTYPE;
  changed_fields text[];
  previous_tag_ids uuid[];
  next_tag_ids uuid[];
  next_locked_fields text[];
  next_title text;
  next_start timestamptz;
  next_end timestamptz;
  next_age_min integer;
  next_age_max integer;
  next_price numeric;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_EVENT_ADMIN_REQUIRED';
  END IF;

  patch := private.admin_validate_event_patch(COALESCE(p_patch, '{}'::jsonb));
  SELECT * INTO before_row FROM public.events WHERE id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ADMIN_EVENT_NOT_FOUND';
  END IF;

  changed_fields := ARRAY(SELECT jsonb_object_keys(patch));
  next_title := CASE WHEN patch ? 'title' THEN NULLIF(btrim(patch->>'title'), '') ELSE before_row.title END;
  next_start := CASE
    WHEN patch ? 'start_datetime' AND jsonb_typeof(patch->'start_datetime') = 'null' THEN NULL
    WHEN patch ? 'start_datetime' THEN (patch->>'start_datetime')::timestamptz
    ELSE before_row.start_datetime
  END;
  next_end := CASE
    WHEN patch ? 'end_datetime' AND jsonb_typeof(patch->'end_datetime') = 'null' THEN NULL
    WHEN patch ? 'end_datetime' THEN (patch->>'end_datetime')::timestamptz
    ELSE before_row.end_datetime
  END;
  next_age_min := CASE
    WHEN patch ? 'age_min' AND jsonb_typeof(patch->'age_min') = 'null' THEN NULL
    WHEN patch ? 'age_min' THEN (patch->>'age_min')::integer
    ELSE before_row.age_min
  END;
  next_age_max := CASE
    WHEN patch ? 'age_max' AND jsonb_typeof(patch->'age_max') = 'null' THEN NULL
    WHEN patch ? 'age_max' THEN (patch->>'age_max')::integer
    ELSE before_row.age_max
  END;
  next_price := CASE
    WHEN patch ? 'price' AND jsonb_typeof(patch->'price') = 'null' THEN NULL
    WHEN patch ? 'price' THEN (patch->>'price')::numeric
    ELSE before_row.price
  END;

  IF next_title IS NULL THEN
    RAISE EXCEPTION 'ADMIN_EVENT_TITLE_REQUIRED';
  END IF;
  IF next_start IS NULL THEN
    RAISE EXCEPTION 'ADMIN_EVENT_TITLE_REQUIRED';
  END IF;
  IF next_end IS NOT NULL AND next_end <= next_start THEN
    RAISE EXCEPTION 'ADMIN_EVENT_END_BEFORE_START';
  END IF;
  IF next_age_min IS NOT NULL AND next_age_max IS NOT NULL AND next_age_min > next_age_max THEN
    RAISE EXCEPTION 'ADMIN_EVENT_INVALID_AGE_RANGE';
  END IF;
  IF next_price IS NOT NULL AND next_price < 0 THEN
    RAISE EXCEPTION 'ADMIN_EVENT_INVALID_PRICE';
  END IF;

  next_locked_fields := CASE
    WHEN p_lock_edited_fields THEN ARRAY(
      SELECT DISTINCT field
      FROM unnest(COALESCE(before_row.admin_locked_fields, '{}'::text[]) || changed_fields) field
      ORDER BY field
    )
    ELSE before_row.admin_locked_fields
  END;

  SELECT COALESCE(array_agg(event_tags.tag_id ORDER BY event_tags.tag_id), '{}'::uuid[])
    INTO previous_tag_ids
  FROM public.event_tags
  WHERE event_tags.event_id = p_event_id;

  next_tag_ids := ARRAY(SELECT DISTINCT tag_id FROM unnest(COALESCE(p_tag_ids, '{}'::uuid[])) tag_id ORDER BY tag_id);

  UPDATE public.events
     SET title = next_title,
         description = CASE WHEN patch ? 'description' AND jsonb_typeof(patch->'description') = 'null' THEN NULL WHEN patch ? 'description' THEN patch->>'description' ELSE description END,
         start_datetime = next_start,
         end_datetime = next_end,
         timezone = CASE WHEN patch ? 'timezone' THEN NULLIF(btrim(patch->>'timezone'), '') ELSE timezone END,
         venue_name = CASE WHEN patch ? 'venue_name' AND jsonb_typeof(patch->'venue_name') = 'null' THEN NULL WHEN patch ? 'venue_name' THEN patch->>'venue_name' ELSE venue_name END,
         address = CASE WHEN patch ? 'address' AND jsonb_typeof(patch->'address') = 'null' THEN NULL WHEN patch ? 'address' THEN patch->>'address' ELSE address END,
         city_id = CASE WHEN patch ? 'city_id' AND jsonb_typeof(patch->'city_id') = 'null' THEN NULL WHEN patch ? 'city_id' THEN (patch->>'city_id')::uuid ELSE city_id END,
         latitude = CASE WHEN patch ? 'latitude' AND jsonb_typeof(patch->'latitude') = 'null' THEN NULL WHEN patch ? 'latitude' THEN (patch->>'latitude')::numeric ELSE latitude END,
         longitude = CASE WHEN patch ? 'longitude' AND jsonb_typeof(patch->'longitude') = 'null' THEN NULL WHEN patch ? 'longitude' THEN (patch->>'longitude')::numeric ELSE longitude END,
         age_min = next_age_min,
         age_max = next_age_max,
         price = next_price,
         is_free = CASE WHEN patch ? 'is_free' THEN (patch->>'is_free')::boolean ELSE is_free END,
         is_outdoor = CASE WHEN patch ? 'is_outdoor' AND jsonb_typeof(patch->'is_outdoor') = 'null' THEN NULL WHEN patch ? 'is_outdoor' THEN (patch->>'is_outdoor')::boolean ELSE is_outdoor END,
         source_url = CASE WHEN patch ? 'source_url' AND jsonb_typeof(patch->'source_url') = 'null' THEN NULL WHEN patch ? 'source_url' THEN patch->>'source_url' ELSE source_url END,
         source_name = CASE WHEN patch ? 'source_name' AND jsonb_typeof(patch->'source_name') = 'null' THEN NULL WHEN patch ? 'source_name' THEN patch->>'source_name' ELSE source_name END,
         source_id = CASE WHEN patch ? 'source_id' AND jsonb_typeof(patch->'source_id') = 'null' THEN NULL WHEN patch ? 'source_id' THEN (patch->>'source_id')::uuid ELSE source_id END,
         images = CASE WHEN patch ? 'images' THEN patch->'images' ELSE images END,
         status = CASE WHEN patch ? 'status' THEN patch->>'status' ELSE status END,
         recurrence_info = CASE WHEN patch ? 'recurrence_info' THEN patch->'recurrence_info' ELSE recurrence_info END,
         is_featured = CASE WHEN patch ? 'is_featured' THEN (patch->>'is_featured')::boolean ELSE is_featured END,
         admin_locked_fields = next_locked_fields,
         admin_last_edited_at = now(),
         admin_last_edited_by = auth.uid(),
         updated_at = now()
   WHERE id = p_event_id
   RETURNING * INTO updated_row;

  DELETE FROM public.event_tags WHERE event_id = p_event_id;
  INSERT INTO public.event_tags (event_id, tag_id, confidence, is_manual_override)
  SELECT p_event_id, tag_id, 1, true
  FROM unnest(next_tag_ids) tag_id;

  INSERT INTO public.admin_audit_log (admin_user_id, action, target_type, target_id, metadata)
  VALUES (
    auth.uid(),
    'event.update',
    'event',
    p_event_id,
    jsonb_build_object(
      'previous', to_jsonb(before_row),
      'patch', patch,
      'changed_fields', to_jsonb(changed_fields),
      'previous_tag_ids', to_jsonb(previous_tag_ids),
      'new_tag_ids', to_jsonb(next_tag_ids),
      'locked_fields_after', to_jsonb(next_locked_fields)
    )
  );

  RETURN updated_row;
END;
$$;


ALTER FUNCTION "private"."admin_update_event"("p_event_id" "uuid", "p_patch" "jsonb", "p_tag_ids" "uuid"[], "p_lock_edited_fields" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."admin_validate_event_patch"("p_patch" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO ''
    AS $$
DECLARE
  allowed_fields constant text[] := ARRAY[
    'title',
    'description',
    'start_datetime',
    'end_datetime',
    'timezone',
    'venue_name',
    'address',
    'city_id',
    'latitude',
    'longitude',
    'age_min',
    'age_max',
    'price',
    'is_free',
    'is_outdoor',
    'source_url',
    'source_name',
    'source_id',
    'images',
    'status',
    'recurrence_info',
    'is_featured'
  ];
  system_fields constant text[] := ARRAY[
    'id',
    'created_at',
    'updated_at',
    'view_count',
    'search_vector',
    'ai_confidence',
    'ai_tag_provider',
    'admin_locked_fields',
    'admin_last_edited_at',
    'admin_last_edited_by'
  ];
  key text;
BEGIN
  IF p_patch IS NULL THEN
    RETURN '{}'::jsonb;
  END IF;

  IF jsonb_typeof(p_patch) <> 'object' THEN
    RAISE EXCEPTION 'ADMIN_EVENT_UNKNOWN_FIELD';
  END IF;

  FOR key IN SELECT jsonb_object_keys(p_patch)
  LOOP
    IF key = ANY(system_fields) THEN
      RAISE EXCEPTION 'ADMIN_EVENT_SYSTEM_FIELD';
    END IF;
    IF NOT key = ANY(allowed_fields) THEN
      RAISE EXCEPTION 'ADMIN_EVENT_UNKNOWN_FIELD';
    END IF;
  END LOOP;

  IF p_patch ? 'images' THEN
    IF jsonb_typeof(p_patch->'images') <> 'array' THEN
      RAISE EXCEPTION 'ADMIN_EVENT_UNKNOWN_FIELD';
    END IF;
    IF EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_patch->'images') image_item
      WHERE jsonb_typeof(image_item) <> 'string'
    ) THEN
      RAISE EXCEPTION 'ADMIN_EVENT_UNKNOWN_FIELD';
    END IF;
  END IF;

  IF p_patch ? 'status'
     AND (p_patch->>'status') NOT IN ('draft', 'published', 'rejected', 'archived') THEN
    RAISE EXCEPTION 'ADMIN_EVENT_INVALID_STATUS';
  END IF;

  RETURN p_patch;
END;
$$;


ALTER FUNCTION "private"."admin_validate_event_patch"("p_patch" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."bootstrap_admin"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  configured_email text;
  target_user_id   uuid;
  promoted_count   int := 0;
BEGIN
  BEGIN
    configured_email := current_setting('app.settings.admin_email', true);
  EXCEPTION WHEN undefined_object THEN
    configured_email := NULL;
  END;

  IF configured_email IS NULL OR configured_email = '' THEN
    RAISE NOTICE 'app.settings.admin_email is not configured — skipping admin bootstrap.';
    RETURN 0;
  END IF;

  SELECT id INTO target_user_id
  FROM public.user_profiles
  WHERE lower(email) = lower(configured_email)
  LIMIT 1;

  IF target_user_id IS NULL THEN
    RAISE NOTICE 'No profile matching % to promote (user may not have signed up yet).', configured_email;
    RETURN 0;
  END IF;

  UPDATE public.user_profiles
  SET role = 'admin', updated_at = now()
  WHERE id = target_user_id AND role <> 'admin';

  GET DIAGNOSTICS promoted_count = ROW_COUNT;

  INSERT INTO public.user_access (
    user_id, is_enabled, enabled_at, disabled_at, disabled_reason, created_at, updated_at
  )
  VALUES (target_user_id, true, now(), NULL, NULL, now(), now())
  ON CONFLICT (user_id) DO UPDATE
    SET is_enabled       = true,
        enabled_at       = COALESCE(public.user_access.enabled_at, now()),
        disabled_at      = NULL,
        disabled_reason  = NULL,
        updated_at       = now();

  IF promoted_count > 0 THEN
    RAISE NOTICE 'Promoted % profile(s) matching % to admin and enabled access.', promoted_count, configured_email;
  ELSE
    RAISE NOTICE 'Admin profile for % already existed; ensured access is enabled.', configured_email;
  END IF;

  RETURN 1;
END;
$$;


ALTER FUNCTION "private"."bootstrap_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."canonicalize_invite_code"("p_code" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  SELECT upper(regexp_replace(coalesce(p_code, ''), '[\s\-_]', '', 'g'));
$$;


ALTER FUNCTION "private"."canonicalize_invite_code"("p_code" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."claim_pending_invite_access"() RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  current_user_id  uuid;
  canonical_email  text;
  claim_exists     boolean;
BEGIN
  current_user_id := auth.uid();
  canonical_email := lower(coalesce(auth.jwt() ->> 'email', ''));

  IF current_user_id IS NULL OR canonical_email = '' THEN
    RETURN false;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.pending_invite_claims
    WHERE email = canonical_email AND claimed_by IS NULL AND expires_at > now()
  ) INTO claim_exists;

  IF NOT claim_exists THEN
    RETURN false;
  END IF;

  INSERT INTO public.user_access (
    user_id, is_enabled, enabled_at, disabled_at, disabled_reason, created_at, updated_at
  )
  VALUES (current_user_id, true, now(), NULL, NULL, now(), now())
  ON CONFLICT (user_id) DO UPDATE
    SET is_enabled      = true,
        enabled_at      = COALESCE(public.user_access.enabled_at, now()),
        disabled_at     = NULL,
        disabled_reason = NULL,
        updated_at      = now();

  UPDATE public.pending_invite_claims
  SET claimed_by = current_user_id, claimed_at = now()
  WHERE email = canonical_email AND claimed_by IS NULL AND expires_at > now();

  RETURN true;
END;
$$;


ALTER FUNCTION "private"."claim_pending_invite_access"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."source_scrape_queue" (
    "id" bigint NOT NULL,
    "source_id" "uuid",
    "source_run_id" "uuid",
    "status" "public"."source_scrape_queue_status" DEFAULT 'pending'::"public"."source_scrape_queue_status" NOT NULL,
    "trigger_type" "text" DEFAULT 'manual'::"text" NOT NULL,
    "attempt_count" integer DEFAULT 0 NOT NULL,
    "enqueued_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "started_at" timestamp with time zone,
    "finished_at" timestamp with time zone,
    "next_attempt_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_error" "text",
    "skip_reason" "text",
    CONSTRAINT "source_scrape_queue_trigger_type_check" CHECK (("trigger_type" = ANY (ARRAY['manual'::"text", 'scheduled'::"text", 'bulk'::"text", 'retry'::"text"])))
);

ALTER TABLE ONLY "public"."source_scrape_queue" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."source_scrape_queue" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."claim_source_scrape_queue_batch"("p_limit" integer DEFAULT 5) RETURNS SETOF "public"."source_scrape_queue"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  RETURN QUERY
  UPDATE public.source_scrape_queue q
  SET status = 'processing',
      started_at = NULL
  WHERE q.id IN (
    SELECT i.id
    FROM public.source_scrape_queue i
    WHERE i.status IN ('pending', 'retrying')
      AND i.next_attempt_at <= now()
    ORDER BY i.next_attempt_at, i.id
    FOR UPDATE SKIP LOCKED
    LIMIT GREATEST(1, LEAST(p_limit, 25))
  )
  RETURNING *;
END;
$$;


ALTER FUNCTION "private"."claim_source_scrape_queue_batch"("p_limit" integer) OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_tag_queue" (
    "id" bigint NOT NULL,
    "event_id" "uuid" NOT NULL,
    "source_run_id" "uuid",
    "trigger_type" "text" DEFAULT 'import'::"text" NOT NULL,
    "enqueued_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "next_attempt_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "started_at" timestamp with time zone,
    "finished_at" timestamp with time zone,
    "attempt_count" integer DEFAULT 0 NOT NULL,
    "last_error" "text",
    "status" "public"."event_tag_queue_status" DEFAULT 'pending'::"public"."event_tag_queue_status" NOT NULL,
    CONSTRAINT "event_tag_queue_trigger_type_check" CHECK (("trigger_type" = ANY (ARRAY['import'::"text", 'reclassify'::"text", 'manual-review'::"text"])))
);

ALTER TABLE ONLY "public"."event_tag_queue" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_tag_queue" OWNER TO "postgres";


COMMENT ON TABLE "public"."event_tag_queue" IS 'Durable queue for tag-event fanout. Workers claim rows via
   public.claim_tag_queue_batch (SKIP LOCKED); failures route to ''pending''
   with exponential backoff until attempt_count reaches MAX_ATTEMPTS, then
   route to ''dead'' for admin review.';



CREATE OR REPLACE FUNCTION "private"."claim_tag_queue_batch"("p_limit" integer DEFAULT 20) RETURNS SETOF "public"."event_tag_queue"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  RETURN QUERY
  UPDATE public.event_tag_queue q SET
    status = 'processing',
    started_at = NULL
  WHERE q.id IN (
    SELECT inner_q.id
    FROM public.event_tag_queue inner_q
    WHERE inner_q.status = 'pending'
      AND inner_q.next_attempt_at <= now()
    ORDER BY inner_q.next_attempt_at
    FOR UPDATE SKIP LOCKED
    LIMIT GREATEST(1, LEAST(p_limit, 100))
  )
  RETURNING *;
END;
$$;


ALTER FUNCTION "private"."claim_tag_queue_batch"("p_limit" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "private"."claim_tag_queue_batch"("p_limit" integer) IS 'Claim up to p_limit (1..100, default 20) pending queue rows whose
   next_attempt_at has elapsed. SKIP LOCKED makes this safe under
   concurrent workers.';



CREATE OR REPLACE FUNCTION "private"."cleanup_stale_source_runs"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  UPDATE public.source_runs
  SET
    status      = 'error',
    completed_at = now(),
    error_log   = 'Run timed out — edge function did not complete within 15 minutes'
  WHERE status = 'running'
    AND started_at < now() - interval '15 minutes';

  -- Propagate to event_sources so the source card shows 'error' not 'pending'
  UPDATE public.event_sources es
  SET last_status = 'error'
  FROM public.source_runs sr
  WHERE sr.source_id = es.id
    AND sr.status = 'error'
    AND sr.error_log = 'Run timed out — edge function did not complete within 15 minutes'
    AND es.last_status = 'running';
END;
$$;


ALTER FUNCTION "private"."cleanup_stale_source_runs"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."current_profile_role"() RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT role FROM public.user_profiles WHERE id = auth.uid();
$$;


ALTER FUNCTION "private"."current_profile_role"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."delete_my_account"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$
declare
    v_user_id uuid := auth.uid();
begin
    if v_user_id is null then
        raise exception 'not authenticated' using errcode = '28000';
    end if;

    -- The auth.users row itself. ON DELETE CASCADE handles all child rows:
    --   auth.identities, auth.sessions, auth.refresh_tokens,
    --   public.user_profiles, and all tables that cascade from user_profiles
    --   (favorites, ratings, comments, user_calendar_events).
    delete from auth.users where id = v_user_id;
end;
$$;


ALTER FUNCTION "private"."delete_my_account"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."dispatch_email_notification"("p_payload" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_supabase_url  text;
  v_service_role  text;
BEGIN
  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'supabase_project_url'
  LIMIT 1;

  IF v_supabase_url IS NULL THEN
    v_supabase_url := current_setting('app.settings.supabase_url', true);
  END IF;

  SELECT decrypted_secret INTO v_service_role
  FROM vault.decrypted_secrets
  WHERE name = 'scrape_service_role_key'
  LIMIT 1;

  IF v_service_role IS NULL THEN
    v_service_role := current_setting('app.settings.service_role_key', true);
  END IF;

  IF v_supabase_url IS NULL OR v_service_role IS NULL THEN
    RAISE NOTICE 'Skipping email notification: missing supabase_url or service_role_key';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url     := v_supabase_url || '/functions/v1/notify-email',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_service_role
    ),
    body    := p_payload
  );
END;
$$;


ALTER FUNCTION "private"."dispatch_email_notification"("p_payload" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."enforce_invited_oauth_signup"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_invite_required boolean;
  v_email text;
  v_primary_provider text;
  v_providers text[] := ARRAY[]::text[];
  v_is_oauth boolean;
  v_claim_exists boolean;
BEGIN
  v_invite_required :=
    lower(btrim(coalesce(current_setting('app.settings.require_invite', true), 'true')))
      IN ('true', 't', '1', 'yes');

  IF NOT v_invite_required THEN
    RETURN NEW;
  END IF;

  v_primary_provider := lower(btrim(coalesce(NEW.raw_app_meta_data->>'provider', '')));

  SELECT coalesce(array_agg(lower(provider_value)), ARRAY[]::text[])
    INTO v_providers
  FROM jsonb_array_elements_text(coalesce(NEW.raw_app_meta_data->'providers', '[]'::jsonb))
       AS providers(provider_value);

  v_is_oauth :=
    v_primary_provider IN ('apple', 'google')
    OR v_providers && ARRAY['apple', 'google']::text[];

  IF NOT v_is_oauth THEN
    RETURN NEW;
  END IF;

  v_email := lower(btrim(coalesce(NEW.email, '')));

  IF v_email = '' THEN
    RAISE EXCEPTION 'Invite required'
      USING
        ERRCODE = 'P0001',
        DETAIL = 'OAuth signup requires a pending invite claim with a verified email.',
        HINT = 'Redeem an invite code for the OAuth email before creating the account.';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.pending_invite_claims
    WHERE email = v_email
      AND claimed_by IS NULL
      AND expires_at > now()
  ) INTO v_claim_exists;

  IF NOT v_claim_exists THEN
    RAISE EXCEPTION 'Invite required'
      USING
        ERRCODE = 'P0001',
        DETAIL = 'OAuth signup requires a pending invite claim.',
        HINT = 'Redeem an invite code for the OAuth email before creating the account.';
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "private"."enforce_invited_oauth_signup"() OWNER TO "postgres";


COMMENT ON FUNCTION "private"."enforce_invited_oauth_signup"() IS 'Blocks new Google/Apple auth.users rows while invite gating is enabled unless a live pending_invite_claims row exists for the OAuth email.';



CREATE OR REPLACE FUNCTION "private"."has_enabled_access"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_access ua
    WHERE ua.user_id = auth.uid()
      AND ua.is_enabled = true
      AND (ua.access_expires_at IS NULL OR ua.access_expires_at > now())
  );
$$;


ALTER FUNCTION "private"."has_enabled_access"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."hash_invite_code"("p_code" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  SELECT encode(extensions.digest(private.canonicalize_invite_code(p_code), 'sha256'), 'hex');
$$;


ALTER FUNCTION "private"."hash_invite_code"("p_code" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."invites_required"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT lower(btrim(coalesce(current_setting('app.settings.require_invite', true), 'true')))
         IN ('true', 't', '1', 'yes');
$$;


ALTER FUNCTION "private"."invites_required"() OWNER TO "postgres";


COMMENT ON FUNCTION "private"."invites_required"() IS 'Returns true when invite gating is on. Defaults to true when app.settings.require_invite is unset.';



CREATE OR REPLACE FUNCTION "private"."is_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_profiles up
    JOIN public.user_access ua ON ua.user_id = up.id
    WHERE up.id = auth.uid()
      AND up.role = 'admin'
      AND ua.is_enabled = true
      AND (ua.access_expires_at IS NULL OR ua.access_expires_at > now())
  );
$$;


ALTER FUNCTION "private"."is_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."is_invite_rate_limited"("p_email_hash" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT count(*) >= 5
  FROM public.invite_redemption_attempts
  WHERE email_hash = p_email_hash
    AND attempted_at > now() - interval '5 minutes'
    AND succeeded = false;
$$;


ALTER FUNCTION "private"."is_invite_rate_limited"("p_email_hash" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."is_invite_request_rate_limited"("p_email_hash" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT count(*) >= 3
  FROM public.invite_request_attempts
  WHERE email_hash = p_email_hash
    AND attempted_at > now() - interval '10 minutes';
$$;


ALTER FUNCTION "private"."is_invite_request_rate_limited"("p_email_hash" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."list_railway_cron_jobs"() RETURNS TABLE("label" "text", "last_run_status" "text", "last_run_at" timestamp with time zone, "last_run_duration_s" integer, "last_http_status" integer)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
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


ALTER FUNCTION "private"."list_railway_cron_jobs"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."log_railway_cron_run"("p_label" "text", "p_status" "text", "p_http_status" integer DEFAULT NULL::integer, "p_duration_s" integer DEFAULT NULL::integer, "p_body" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  INSERT INTO private.railway_cron_runs (label, status, http_status, duration_s, body)
  VALUES (p_label, p_status, p_http_status, p_duration_s, p_body);
$$;


ALTER FUNCTION "private"."log_railway_cron_run"("p_label" "text", "p_status" "text", "p_http_status" integer, "p_duration_s" integer, "p_body" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."mark_source_scrape_queue_skipped"("p_queue_id" bigint, "p_skip_reason" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  UPDATE public.source_scrape_queue
  SET status = 'succeeded',
      finished_at = now(),
      skip_reason = left(coalesce(p_skip_reason, 'source skipped'), 1000),
      last_error = NULL
  WHERE id = p_queue_id;
END;
$$;


ALTER FUNCTION "private"."mark_source_scrape_queue_skipped"("p_queue_id" bigint, "p_skip_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."mark_source_scrape_queue_started"("p_queue_id" bigint) RETURNS "public"."source_scrape_queue"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_row public.source_scrape_queue;
BEGIN
  UPDATE public.source_scrape_queue
  SET started_at = now(),
      attempt_count = attempt_count + 1
  WHERE id = p_queue_id
    AND status = 'processing'
    AND started_at IS NULL
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;


ALTER FUNCTION "private"."mark_source_scrape_queue_started"("p_queue_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."mark_tag_queue_row_started"("p_queue_id" bigint) RETURNS "public"."event_tag_queue"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_row public.event_tag_queue;
BEGIN
  UPDATE public.event_tag_queue
  SET started_at = now(),
      attempt_count = attempt_count + 1
  WHERE id = p_queue_id
    AND status = 'processing'
    AND started_at IS NULL
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;


ALTER FUNCTION "private"."mark_tag_queue_row_started"("p_queue_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."plan_events_first_nonempty_window"("p_user_id" "uuid", "p_date" "date" DEFAULT (("now"() AT TIME ZONE 'utc'::"text"))::"date", "p_city_id" "uuid" DEFAULT NULL::"uuid", "p_lat" double precision DEFAULT NULL::double precision, "p_lng" double precision DEFAULT NULL::double precision, "p_kid_age" integer DEFAULT NULL::integer, "p_weather_fit" "text" DEFAULT 'neutral'::"text", "p_limit" integer DEFAULT 3, "p_max_days" integer DEFAULT 7) RETURNS TABLE("day_offset" integer, "event_id" "uuid", "score" numeric, "distance_score" numeric, "weather_score" numeric, "age_score" numeric, "history_affinity" numeric, "distance_km" numeric)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_offset int;
  v_found  boolean := false;
BEGIN
  IF p_user_id IS NOT NULL
     AND p_user_id IS DISTINCT FROM auth.uid()
     AND NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden: p_user_id must match auth.uid()'
      USING ERRCODE = '42501';
  END IF;

  -- Cap p_max_days so a buggy caller can't spin 365 iterations.
  IF p_max_days IS NULL OR p_max_days < 0 THEN
    p_max_days := 0;
  ELSIF p_max_days > 14 THEN
    p_max_days := 14;
  END IF;

  FOR v_offset IN 0..p_max_days LOOP
    RETURN QUERY
    SELECT
      v_offset AS day_offset,
      pe.event_id,
      pe.score,
      pe.distance_score,
      pe.weather_score,
      pe.age_score,
      pe.history_affinity,
      pe.distance_km
    FROM public.plan_events_for_user(
      p_user_id,
      (p_date + (v_offset || ' days')::interval)::date,
      p_city_id, p_lat, p_lng, p_kid_age, p_weather_fit, p_limit
    ) pe;

    -- FOUND reflects whether the most recent RETURN QUERY produced rows.
    -- Once we have a non-empty day, stop iterating.
    IF FOUND THEN
      v_found := true;
      EXIT;
    END IF;
  END LOOP;

  IF NOT v_found THEN
    -- Empty result already returned implicitly; no further action.
    RETURN;
  END IF;
END;
$$;


ALTER FUNCTION "private"."plan_events_first_nonempty_window"("p_user_id" "uuid", "p_date" "date", "p_city_id" "uuid", "p_lat" double precision, "p_lng" double precision, "p_kid_age" integer, "p_weather_fit" "text", "p_limit" integer, "p_max_days" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "private"."plan_events_first_nonempty_window"("p_user_id" "uuid", "p_date" "date", "p_city_id" "uuid", "p_lat" double precision, "p_lng" double precision, "p_kid_age" integer, "p_weather_fit" "text", "p_limit" integer, "p_max_days" integer) IS 'Returns the first non-empty day (offset 0..p_max_days, capped at 14) from
   plan_events_for_user. day_offset is included on every row so the caller
   can derive the selected date. Authorization mirrors plan_events_for_user:
   p_user_id must match auth.uid() unless caller is admin.';



CREATE OR REPLACE FUNCTION "private"."railway_cron_run_history"("p_label" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 50) RETURNS TABLE("id" bigint, "label" "text", "status" "text", "http_status" integer, "duration_s" integer, "body" "text", "ran_at" timestamp with time zone)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT id, label, status, http_status, duration_s, body, ran_at
  FROM private.railway_cron_runs
  WHERE p_label IS NULL OR label = p_label
  ORDER BY ran_at DESC
  LIMIT LEAST(p_limit, 200);
$$;


ALTER FUNCTION "private"."railway_cron_run_history"("p_label" "text", "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."reap_stuck_source_scrape_queue_rows"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_count int;
BEGIN
  UPDATE public.source_scrape_queue
  SET status = 'retrying',
      started_at = NULL,
      source_run_id = CASE WHEN started_at IS NULL THEN NULL ELSE source_run_id END,
      last_error = coalesce(last_error, 'reaped after stuck in processing')
  WHERE status = 'processing'
    AND (
      (started_at IS NULL  AND next_attempt_at < now() - interval '5 minutes')
      OR started_at < now() - interval '15 minutes'
    );
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;


ALTER FUNCTION "private"."reap_stuck_source_scrape_queue_rows"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."reap_stuck_tag_queue_rows"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_count int;
BEGIN
  UPDATE public.event_tag_queue
  SET status = 'pending',
      started_at = NULL,
      last_error = coalesce(last_error, 'reaped after stuck in processing')
  WHERE status = 'processing'
    AND (
      (started_at IS NULL  AND next_attempt_at < now() - interval '5 minutes')
      OR started_at < now() - interval '15 minutes'
    );

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;


ALTER FUNCTION "private"."reap_stuck_tag_queue_rows"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."redeem_invite"("p_code" "text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_code_hash      text;
  v_invite_row_id  uuid;
  v_invite_used    int;
  v_invite_max     int;
  v_invite_expires timestamptz;
  v_invite_revoked timestamptz;
BEGIN
  IF coalesce(btrim(p_code), '') = '' THEN
    RETURN false;
  END IF;

  v_code_hash := private.hash_invite_code(p_code);

  SELECT id, used_count, max_uses, expires_at, revoked_at
    INTO v_invite_row_id, v_invite_used, v_invite_max, v_invite_expires, v_invite_revoked
  FROM public.invite_codes
  WHERE code_hash = v_code_hash
  FOR UPDATE;

  IF v_invite_row_id IS NULL
     OR v_invite_revoked IS NOT NULL
     OR v_invite_used >= v_invite_max
     OR (v_invite_expires IS NOT NULL AND v_invite_expires < now()) THEN
    RETURN false;
  END IF;

  UPDATE public.invite_codes
  SET used_count = used_count + 1
  WHERE id = v_invite_row_id;

  RETURN true;
END;
$$;


ALTER FUNCTION "private"."redeem_invite"("p_code" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."redeem_invite_for_email"("p_code" "text", "p_email" "text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_canonical_email text;
  v_email_hash      text;
  v_code_hash       text;
  v_invite_row_id   uuid;
  v_invite_used     int;
  v_invite_max      int;
  v_invite_expires  timestamptz;
  v_invite_revoked  timestamptz;
  v_existing_hash   text;
BEGIN
  v_canonical_email := lower(btrim(coalesce(p_email, '')));

  IF v_canonical_email = '' OR coalesce(btrim(p_code), '') = '' THEN
    RETURN false;
  END IF;

  v_email_hash := encode(extensions.digest(v_canonical_email, 'sha256'), 'hex');
  v_code_hash  := private.hash_invite_code(p_code);

  IF private.is_invite_rate_limited(v_email_hash) THEN
    RETURN false;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.pending_invite_claims
    WHERE email = v_canonical_email
      AND invite_code = v_code_hash
      AND claimed_by IS NULL
      AND expires_at > now()
  ) THEN
    RETURN true;
  END IF;

  SELECT id, used_count, max_uses, expires_at, revoked_at
    INTO v_invite_row_id, v_invite_used, v_invite_max, v_invite_expires, v_invite_revoked
  FROM public.invite_codes
  WHERE code_hash = v_code_hash
  FOR UPDATE;

  IF v_invite_row_id IS NULL
     OR v_invite_revoked IS NOT NULL
     OR v_invite_used >= v_invite_max
     OR (v_invite_expires IS NOT NULL AND v_invite_expires < now()) THEN
    INSERT INTO public.invite_redemption_attempts (email_hash, succeeded)
      VALUES (v_email_hash, false);
    RETURN false;
  END IF;

  SELECT invite_code INTO v_existing_hash
  FROM public.pending_invite_claims
  WHERE email = v_canonical_email
    AND claimed_by IS NULL
    AND expires_at > now()
  LIMIT 1;

  IF v_existing_hash IS NOT NULL AND v_existing_hash <> v_code_hash THEN
    UPDATE public.invite_codes
    SET used_count = GREATEST(used_count - 1, 0)
    WHERE code_hash = v_existing_hash;
  END IF;

  UPDATE public.invite_codes
  SET used_count = used_count + 1
  WHERE id = v_invite_row_id;

  INSERT INTO public.pending_invite_claims (email, invite_code, expires_at, claimed_by, claimed_at, created_at)
  VALUES (v_canonical_email, v_code_hash, now() + interval '2 hours', NULL, NULL, now())
  ON CONFLICT (email) DO UPDATE
    SET invite_code = EXCLUDED.invite_code,
        expires_at  = EXCLUDED.expires_at,
        claimed_by  = NULL,
        claimed_at  = NULL,
        created_at  = now();

  INSERT INTO public.invite_redemption_attempts (email_hash, succeeded)
    VALUES (v_email_hash, true);

  RETURN true;
END;
$$;


ALTER FUNCTION "private"."redeem_invite_for_email"("p_code" "text", "p_email" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."refresh_timezone_names"() RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  REFRESH MATERIALIZED VIEW CONCURRENTLY private.timezone_names_cache;
$$;


ALTER FUNCTION "private"."refresh_timezone_names"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."release_unstarted_source_scrape_queue_rows"("p_claimed_ids" bigint[]) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_count int;
BEGIN
  UPDATE public.source_scrape_queue
  SET status = 'pending',
      started_at = NULL
  WHERE id = ANY(p_claimed_ids)
    AND status = 'processing'
    AND started_at IS NULL
    AND source_run_id IS NULL;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;


ALTER FUNCTION "private"."release_unstarted_source_scrape_queue_rows"("p_claimed_ids" bigint[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."release_unstarted_tag_queue_rows"("p_claimed_ids" bigint[]) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_count int;
BEGIN
  UPDATE public.event_tag_queue
  SET status = 'pending',
      started_at = NULL
  WHERE id = ANY(p_claimed_ids)
    AND status = 'processing'
    AND started_at IS NULL
    AND finished_at IS NULL;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;


ALTER FUNCTION "private"."release_unstarted_tag_queue_rows"("p_claimed_ids" bigint[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."request_invite"("p_email" "text", "p_message" "text" DEFAULT NULL::"text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_canonical_email text;
  v_email_hash      text;
  v_trimmed_message text;
  v_request_id      uuid;
BEGIN
  v_canonical_email := lower(btrim(coalesce(p_email, '')));
  IF v_canonical_email = '' OR position('@' IN v_canonical_email) = 0 THEN
    RETURN false;
  END IF;

  v_email_hash := encode(extensions.digest(v_canonical_email, 'sha256'), 'hex');

  IF private.is_invite_request_rate_limited(v_email_hash) THEN
    RETURN false;
  END IF;

  v_trimmed_message := nullif(btrim(coalesce(p_message, '')), '');
  IF v_trimmed_message IS NOT NULL AND length(v_trimmed_message) > 500 THEN
    v_trimmed_message := substring(v_trimmed_message FROM 1 FOR 500);
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.invite_requests
    WHERE lower(email) = v_canonical_email AND status = 'pending'
  ) THEN
    UPDATE public.invite_requests
    SET message = coalesce(v_trimmed_message, message)
    WHERE lower(email) = v_canonical_email AND status = 'pending'
    RETURNING id INTO v_request_id;
  ELSE
    INSERT INTO public.invite_requests (email, message)
    VALUES (v_canonical_email, v_trimmed_message)
    RETURNING id INTO v_request_id;
  END IF;

  INSERT INTO public.invite_request_attempts (email_hash, succeeded)
    VALUES (v_email_hash, true);

  -- Notify the admin async. Wrapped in EXCEPTION so a vault/secret hiccup
  -- never bubbles up to the anon caller — the request is already persisted.
  BEGIN
    PERFORM private.dispatch_email_notification(jsonb_build_object(
      'kind',       'admin_request',
      'request_id', v_request_id,
      'email',      v_canonical_email,
      'message',    v_trimmed_message
    ));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Failed to dispatch admin invite-request email: %', SQLERRM;
  END;

  RETURN true;
END;
$$;


ALTER FUNCTION "private"."request_invite"("p_email" "text", "p_message" "text") OWNER TO "postgres";


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


ALTER FUNCTION "private"."run_daily_maintenance"() OWNER TO "postgres";


COMMENT ON FUNCTION "private"."run_daily_maintenance"() IS 'Daily prune: event_tag_queue dead/failed, invite_request_attempts, invite_redemption_attempts, recommendation_signals. Invoked by the cron-db-maintenance Railway service via the db-maintenance edge function.';



CREATE OR REPLACE FUNCTION "private"."source_scrape_queue_schedule_retry"("p_queue_id" bigint, "p_attempt_count" integer, "p_error" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_next timestamptz;
BEGIN
  IF p_attempt_count >= 4 THEN
    UPDATE public.source_scrape_queue
    SET status = 'dead',
        finished_at = now(),
        last_error = left(coalesce(p_error, ''), 1000)
    WHERE id = p_queue_id;
    RETURN;
  END IF;

  v_next := CASE
    WHEN p_attempt_count = 1 THEN now() + interval '5 minutes'
    WHEN p_attempt_count = 2 THEN now() + interval '15 minutes'
    ELSE now() + interval '60 minutes'
  END;

  UPDATE public.source_scrape_queue
  SET status = 'pending',
      started_at = NULL,
      next_attempt_at = v_next,
      last_error = left(coalesce(p_error, ''), 1000)
  WHERE id = p_queue_id;
END;
$$;


ALTER FUNCTION "private"."source_scrape_queue_schedule_retry"("p_queue_id" bigint, "p_attempt_count" integer, "p_error" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."user_access_set_audit_timestamps"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.is_enabled THEN
      NEW.enabled_at := COALESCE(NEW.enabled_at, now());
      NEW.disabled_at := NULL;
    ELSE
      NEW.disabled_at := COALESCE(NEW.disabled_at, now());
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE: only react when is_enabled actually changes.
  IF NEW.is_enabled IS DISTINCT FROM OLD.is_enabled THEN
    IF NEW.is_enabled THEN
      NEW.enabled_at := COALESCE(NEW.enabled_at, now());
      NEW.disabled_at := NULL;
      NEW.disabled_reason := NULL;
    ELSE
      NEW.disabled_at := COALESCE(NEW.disabled_at, now());
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "private"."user_access_set_audit_timestamps"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_approve_invite_request"("p_request_id" "uuid") RETURNS TABLE("request_id" "uuid", "code" "text", "invite_code_id" "uuid", "email" "text", "created_at" timestamp with time zone)
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$ SELECT * FROM private.admin_approve_invite_request(p_request_id); $$;


ALTER FUNCTION "public"."admin_approve_invite_request"("p_request_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_bulk_set_auto_approve"("enable" boolean) RETURNS "void"
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$ SELECT private.admin_bulk_set_auto_approve(enable); $$;


ALTER FUNCTION "public"."admin_bulk_set_auto_approve"("enable" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_create_event"("p_patch" "jsonb", "p_tag_ids" "uuid"[] DEFAULT '{}'::"uuid"[]) RETURNS "public"."events"
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
  SELECT * FROM private.admin_create_event(p_patch, p_tag_ids);
$$;


ALTER FUNCTION "public"."admin_create_event"("p_patch" "jsonb", "p_tag_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_create_invite_code"("p_max_uses" integer DEFAULT 1, "p_expires_at" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_notes" "text" DEFAULT NULL::"text") RETURNS TABLE("id" "uuid", "code" "text", "max_uses" integer, "expires_at" timestamp with time zone, "notes" "text", "created_at" timestamp with time zone)
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$ SELECT * FROM private.admin_create_invite_code(p_max_uses, p_expires_at, p_notes); $$;


ALTER FUNCTION "public"."admin_create_invite_code"("p_max_uses" integer, "p_expires_at" timestamp with time zone, "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_cron_run_history"("p_job_name" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 50) RETURNS TABLE("runid" bigint, "jobname" "text", "status" "text", "return_message" "text", "start_time" timestamp with time zone, "end_time" timestamp with time zone, "duration_ms" numeric)
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$ SELECT * FROM private.admin_cron_run_history(p_job_name, p_limit); $$;


ALTER FUNCTION "public"."admin_cron_run_history"("p_job_name" "text", "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_delete_rating"("p_id" "uuid") RETURNS boolean
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
  SELECT private.admin_delete_rating(p_id);
$$;


ALTER FUNCTION "public"."admin_delete_rating"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_list_cron_jobs"() RETURNS TABLE("jobid" bigint, "jobname" "text", "schedule" "text", "command" "text", "active" boolean, "last_run_start" timestamp with time zone, "last_run_end" timestamp with time zone, "last_run_status" "text", "last_run_message" "text")
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$ SELECT * FROM private.admin_list_cron_jobs(); $$;


ALTER FUNCTION "public"."admin_list_cron_jobs"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_list_railway_cron_jobs"() RETURNS TABLE("label" "text", "last_run_status" "text", "last_run_at" timestamp with time zone, "last_run_duration_s" integer, "last_http_status" integer)
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
  SELECT * FROM private.list_railway_cron_jobs();
$$;


ALTER FUNCTION "public"."admin_list_railway_cron_jobs"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_railway_cron_run_history"("p_label" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 50) RETURNS TABLE("id" bigint, "label" "text", "status" "text", "http_status" integer, "duration_s" integer, "body" "text", "ran_at" timestamp with time zone)
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
  SELECT * FROM private.railway_cron_run_history(p_label, p_limit);
$$;


ALTER FUNCTION "public"."admin_railway_cron_run_history"("p_label" "text", "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_reject_invite_request"("p_request_id" "uuid", "p_notes" "text" DEFAULT NULL::"text") RETURNS boolean
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$ SELECT private.admin_reject_invite_request(p_request_id, p_notes); $$;


ALTER FUNCTION "public"."admin_reject_invite_request"("p_request_id" "uuid", "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_retry_source_scrape_queue"("p_queue_id" bigint) RETURNS boolean
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$ SELECT private.admin_retry_source_scrape_queue(p_queue_id); $$;


ALTER FUNCTION "public"."admin_retry_source_scrape_queue"("p_queue_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_retry_tag_queue"("p_event_id" "uuid") RETURNS boolean
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$ SELECT private.admin_retry_tag_queue(p_event_id); $$;


ALTER FUNCTION "public"."admin_retry_tag_queue"("p_event_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_revoke_invite_code"("p_id" "uuid") RETURNS boolean
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
  SELECT private.admin_revoke_invite_code(p_id);
$$;


ALTER FUNCTION "public"."admin_revoke_invite_code"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_run_due_scrapes"() RETURNS "void"
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$ SELECT private.admin_run_due_scrapes(); $$;


ALTER FUNCTION "public"."admin_run_due_scrapes"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_set_cron_schedule"("p_job_name" "text", "p_schedule" "text") RETURNS "void"
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$ SELECT private.admin_set_cron_schedule(p_job_name, p_schedule); $$;


ALTER FUNCTION "public"."admin_set_cron_schedule"("p_job_name" "text", "p_schedule" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_toggle_cron_job"("p_job_name" "text", "p_active" boolean) RETURNS "void"
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$ SELECT private.admin_toggle_cron_job(p_job_name, p_active); $$;


ALTER FUNCTION "public"."admin_toggle_cron_job"("p_job_name" "text", "p_active" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_unlock_event_fields"("p_event_id" "uuid") RETURNS boolean
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
  SELECT private.admin_unlock_event_fields(p_event_id);
$$;


ALTER FUNCTION "public"."admin_unlock_event_fields"("p_event_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_update_event"("p_event_id" "uuid", "p_patch" "jsonb", "p_tag_ids" "uuid"[], "p_lock_edited_fields" boolean DEFAULT true) RETURNS "public"."events"
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
  SELECT * FROM private.admin_update_event(p_event_id, p_patch, p_tag_ids, p_lock_edited_fields);
$$;


ALTER FUNCTION "public"."admin_update_event"("p_event_id" "uuid", "p_patch" "jsonb", "p_tag_ids" "uuid"[], "p_lock_edited_fields" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."claim_pending_invite_access"() RETURNS boolean
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$ SELECT private.claim_pending_invite_access(); $$;


ALTER FUNCTION "public"."claim_pending_invite_access"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."claim_source_scrape_queue_batch"("p_limit" integer DEFAULT 5) RETURNS SETOF "public"."source_scrape_queue"
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$ SELECT * FROM private.claim_source_scrape_queue_batch(p_limit); $$;


ALTER FUNCTION "public"."claim_source_scrape_queue_batch"("p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."claim_tag_queue_batch"("p_limit" integer DEFAULT 5) RETURNS SETOF "public"."event_tag_queue"
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$ SELECT * FROM private.claim_tag_queue_batch(p_limit); $$;


ALTER FUNCTION "public"."claim_tag_queue_batch"("p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_my_account"() RETURNS "void"
    LANGUAGE "sql"
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$
    select private.delete_my_account();
$$;


ALTER FUNCTION "public"."delete_my_account"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."delete_my_account"() IS 'Deletes the calling user''s account and per-user app data. Anon-callable: NO. Used by web /profile and iOS Profile sheet.';



CREATE OR REPLACE FUNCTION "public"."events_enriched"("p_city_id" "uuid" DEFAULT NULL::"uuid", "p_status" "text" DEFAULT 'published'::"text", "p_limit" integer DEFAULT 100, "p_offset" integer DEFAULT 0, "p_user_id" "uuid" DEFAULT NULL::"uuid", "p_event_ids" "uuid"[] DEFAULT NULL::"uuid"[], "p_date_from" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_date_to" timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS TABLE("id" "uuid", "title" "text", "description" "text", "start_datetime" timestamp with time zone, "end_datetime" timestamp with time zone, "timezone" "text", "venue_name" "text", "address" "text", "city_id" "uuid", "latitude" numeric, "longitude" numeric, "age_min" integer, "age_max" integer, "price" numeric, "is_free" boolean, "source_url" "text", "source_name" "text", "source_id" "uuid", "images" "jsonb", "status" "text", "ai_confidence" numeric, "ai_tag_provider" "text", "recurrence_info" "jsonb", "is_featured" boolean, "view_count" integer, "search_vector" "tsvector", "created_at" timestamp with time zone, "updated_at" timestamp with time zone, "avg_rating" numeric, "rating_count" integer, "tags" "jsonb", "is_favorited" boolean, "is_in_calendar" boolean)
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT
    e.id, e.title, e.description, e.start_datetime, e.end_datetime, e.timezone,
    e.venue_name, e.address, e.city_id, e.latitude, e.longitude,
    e.age_min, e.age_max, e.price, e.is_free,
    e.source_url, e.source_name, e.source_id, e.images, e.status,
    e.ai_confidence, e.ai_tag_provider, e.recurrence_info, e.is_featured, e.view_count,
    e.search_vector, e.created_at, e.updated_at,
    COALESCE(rs.avg_score, 0)::numeric    AS avg_rating,
    COALESCE(rs.rating_count, 0)::int     AS rating_count,
    COALESCE(ts.tags, '[]'::jsonb)        AS tags,
    (p_user_id IS NOT NULL AND f.event_id IS NOT NULL)  AS is_favorited,
    (p_user_id IS NOT NULL AND c.event_id IS NOT NULL)  AS is_in_calendar
  FROM public.events e
  LEFT JOIN LATERAL (
    SELECT ROUND(AVG(r.score)::numeric, 1) AS avg_score,
           COUNT(*)::int AS rating_count
    FROM public.ratings r
    WHERE r.event_id = e.id
  ) rs ON TRUE
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(
             jsonb_build_object('id', t.id, 'name', t.name, 'slug', t.slug, 'color', t.color)
             ORDER BY t.name
           ) AS tags
    FROM public.event_tags et
    JOIN public.tags t ON t.id = et.tag_id
    WHERE et.event_id = e.id
  ) ts ON TRUE
  LEFT JOIN public.favorites f
    ON p_user_id IS NOT NULL AND f.event_id = e.id AND f.user_id = p_user_id
  LEFT JOIN public.user_calendar_events c
    ON p_user_id IS NOT NULL AND c.event_id = e.id AND c.user_id = p_user_id
  WHERE
    (p_date_from IS NULL OR e.start_datetime >= p_date_from)
    AND (p_date_to IS NULL OR e.start_datetime <= p_date_to)
    AND (
      p_event_ids IS NOT NULL AND e.id = ANY(p_event_ids)
      OR p_event_ids IS NULL
        AND e.status = p_status
        AND (p_city_id IS NULL OR e.city_id = p_city_id)
    )
  ORDER BY e.start_datetime ASC
  LIMIT  CASE WHEN p_event_ids IS NULL THEN p_limit  ELSE NULL END
  OFFSET CASE WHEN p_event_ids IS NULL THEN p_offset ELSE 0    END;
$$;


ALTER FUNCTION "public"."events_enriched"("p_city_id" "uuid", "p_status" "text", "p_limit" integer, "p_offset" integer, "p_user_id" "uuid", "p_event_ids" "uuid"[], "p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  invite_required boolean;
  v_username      text;
BEGIN
  invite_required :=
    COALESCE(current_setting('app.settings.require_invite', true), 'true') = 'true';

  v_username := coalesce(
    NEW.raw_user_meta_data->>'display_name',
    split_part(NEW.email, '@', 1)
  );

  INSERT INTO public.user_profiles (id, email, display_name)
  VALUES (NEW.id, NEW.email, v_username)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.user_access (
    user_id, is_enabled, enabled_at, disabled_at, disabled_reason, created_at, updated_at
  )
  VALUES (
    NEW.id,
    NOT invite_required,
    CASE WHEN invite_required THEN NULL ELSE now() END,
    NULL, NULL, now(), now()
  )
  ON CONFLICT (user_id) DO NOTHING;

  -- Fire welcome email async. Wrapped in EXCEPTION so a vault/secret hiccup
  -- never bubbles up — the profile + access rows are already committed above.
  BEGIN
    PERFORM private.dispatch_email_notification(jsonb_build_object(
      'kind',     'welcome',
      'email',    NEW.email,
      'username', v_username
    ));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Failed to dispatch welcome email for %: %', NEW.email, SQLERRM;
  END;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."invites_required"() RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$ SELECT private.invites_required(); $$;


ALTER FUNCTION "public"."invites_required"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."invoke_process_tag_queue"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_supabase_url  text;
  v_service_role  text;
  v_reaped        int;
BEGIN
  -- Vault first (works on Supabase Cloud), GUC fallback (works locally).
  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'supabase_project_url'
  LIMIT 1;

  IF v_supabase_url IS NULL THEN
    v_supabase_url := current_setting('app.settings.supabase_url', true);
  END IF;

  SELECT decrypted_secret INTO v_service_role
  FROM vault.decrypted_secrets
  WHERE name = 'scrape_service_role_key'
  LIMIT 1;

  IF v_service_role IS NULL THEN
    v_service_role := current_setting('app.settings.service_role_key', true);
  END IF;

  IF v_supabase_url IS NULL OR v_service_role IS NULL THEN
    RAISE NOTICE 'Skipping process-tag-queue: missing supabase_url or service_role_key';
    RETURN;
  END IF;

  -- Reap rows stuck in 'processing' for >5 min before checking the guard,
  -- so a crashed worker doesn't block the queue indefinitely.
  v_reaped := public.reap_stuck_tag_queue_rows();
  IF v_reaped > 0 THEN
    RAISE NOTICE 'reaped % stuck tag-queue rows', v_reaped;
  END IF;

  -- Skip if a batch is already running — prevents Ollama request pile-up.
  IF EXISTS (
    SELECT 1 FROM public.event_tag_queue WHERE status = 'processing' LIMIT 1
  ) THEN
    RAISE NOTICE 'process-tag-queue: batch already in flight, skipping tick';
    RETURN;
  END IF;

  -- Skip if nothing is pending.
  IF NOT EXISTS (
    SELECT 1 FROM public.event_tag_queue
    WHERE status = 'pending' AND next_attempt_at <= now()
    LIMIT 1
  ) THEN
    RETURN;
  END IF;

  PERFORM net.http_post(
    url                  := v_supabase_url || '/functions/v1/process-tag-queue',
    headers              := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_service_role
    ),
    body                 := '{}'::jsonb,
    timeout_milliseconds := 120000
  );
END;
$$;


ALTER FUNCTION "public"."invoke_process_tag_queue"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."invoke_scrape_source"("source_uuid" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_supabase_url  text;
  v_service_role  text;
BEGIN
  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'supabase_project_url'
  LIMIT 1;

  IF v_supabase_url IS NULL THEN
    v_supabase_url := current_setting('app.settings.supabase_url', true);
  END IF;

  SELECT decrypted_secret INTO v_service_role
  FROM vault.decrypted_secrets
  WHERE name = 'scrape_service_role_key'
  LIMIT 1;

  IF v_service_role IS NULL THEN
    v_service_role := current_setting('app.settings.service_role_key', true);
  END IF;

  IF v_supabase_url IS NULL OR v_service_role IS NULL THEN
    RAISE NOTICE 'Skipping scrape: no supabase_url or service_role_key configured (vault or app.settings)';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url     := v_supabase_url || '/functions/v1/scrape-source',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_service_role
    ),
    body    := jsonb_build_object('source_id', source_uuid)
  );
END;
$$;


ALTER FUNCTION "public"."invoke_scrape_source"("source_uuid" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."invoke_scrape_source"("source_uuid" "uuid") IS 'Reads supabase_url and service-role key from vault.secrets (names:
   supabase_project_url, scrape_service_role_key) with app.settings GUC
   fallback for local-dev parity.';



CREATE OR REPLACE FUNCTION "public"."is_enabled_user"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT private.has_enabled_access();
$$;


ALTER FUNCTION "public"."is_enabled_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."log_railway_cron_run"("p_label" "text", "p_status" "text", "p_http_status" integer DEFAULT NULL::integer, "p_duration_s" integer DEFAULT NULL::integer, "p_body" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
  SELECT private.log_railway_cron_run(p_label, p_status, p_http_status, p_duration_s, p_body);
$$;


ALTER FUNCTION "public"."log_railway_cron_run"("p_label" "text", "p_status" "text", "p_http_status" integer, "p_duration_s" integer, "p_body" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mark_source_scrape_queue_skipped"("p_queue_id" bigint, "p_skip_reason" "text") RETURNS "void"
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$ SELECT private.mark_source_scrape_queue_skipped(p_queue_id, p_skip_reason); $$;


ALTER FUNCTION "public"."mark_source_scrape_queue_skipped"("p_queue_id" bigint, "p_skip_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mark_source_scrape_queue_started"("p_queue_id" bigint) RETURNS "public"."source_scrape_queue"
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$ SELECT private.mark_source_scrape_queue_started(p_queue_id); $$;


ALTER FUNCTION "public"."mark_source_scrape_queue_started"("p_queue_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mark_tag_queue_row_started"("p_queue_id" bigint) RETURNS "public"."event_tag_queue"
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$ SELECT private.mark_tag_queue_row_started(p_queue_id); $$;


ALTER FUNCTION "public"."mark_tag_queue_row_started"("p_queue_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."plan_events_first_nonempty_window"("p_user_id" "uuid", "p_date" "date" DEFAULT (("now"() AT TIME ZONE 'utc'::"text"))::"date", "p_city_id" "uuid" DEFAULT NULL::"uuid", "p_lat" double precision DEFAULT NULL::double precision, "p_lng" double precision DEFAULT NULL::double precision, "p_kid_age" integer DEFAULT NULL::integer, "p_weather_fit" "text" DEFAULT 'neutral'::"text", "p_limit" integer DEFAULT 3, "p_max_days" integer DEFAULT 7) RETURNS TABLE("day_offset" integer, "event_id" "uuid", "score" numeric, "distance_score" numeric, "weather_score" numeric, "age_score" numeric, "history_affinity" numeric, "distance_km" numeric)
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT * FROM private.plan_events_first_nonempty_window(
    p_user_id, p_date, p_city_id, p_lat, p_lng, p_kid_age, p_weather_fit, p_limit, p_max_days
  );
$$;


ALTER FUNCTION "public"."plan_events_first_nonempty_window"("p_user_id" "uuid", "p_date" "date", "p_city_id" "uuid", "p_lat" double precision, "p_lng" double precision, "p_kid_age" integer, "p_weather_fit" "text", "p_limit" integer, "p_max_days" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."plan_events_for_user"("p_user_id" "uuid", "p_date" "date" DEFAULT (("now"() AT TIME ZONE 'utc'::"text"))::"date", "p_city_id" "uuid" DEFAULT NULL::"uuid", "p_lat" double precision DEFAULT NULL::double precision, "p_lng" double precision DEFAULT NULL::double precision, "p_kid_age" integer DEFAULT NULL::integer, "p_weather_fit" "text" DEFAULT 'neutral'::"text", "p_limit" integer DEFAULT 3) RETURNS TABLE("event_id" "uuid", "score" numeric, "distance_score" numeric, "weather_score" numeric, "age_score" numeric, "history_affinity" numeric, "distance_km" numeric)
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO ''
    AS $$
BEGIN
  IF p_user_id IS NOT NULL
     AND p_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'forbidden: p_user_id must match auth.uid()'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH user_favorite_tags AS (
    SELECT et.tag_id
    FROM public.favorites f
    JOIN public.event_tags et ON et.event_id = f.event_id
    WHERE f.user_id = p_user_id
    GROUP BY et.tag_id
  ),
  candidate_events AS (
    SELECT e.id, e.age_min, e.age_max, e.latitude, e.longitude, e.is_outdoor
    FROM public.events e
    WHERE e.status = 'published'
      AND (p_city_id IS NULL OR e.city_id = p_city_id)
      AND (e.start_datetime AT TIME ZONE e.timezone)::date = p_date
  ),
  event_history AS (
    SELECT
      et.event_id,
      COUNT(et.tag_id)::numeric AS tag_count,
      COUNT(et.tag_id) FILTER (WHERE uft.tag_id IS NOT NULL)::numeric AS matching_tag_count
    FROM public.event_tags et
    JOIN candidate_events ce ON ce.id = et.event_id
    LEFT JOIN user_favorite_tags uft ON uft.tag_id = et.tag_id
    GROUP BY et.event_id
  ),
  scored_events AS (
    SELECT
      e.id AS event_id,
      CASE
        WHEN p_lat IS NULL OR p_lng IS NULL OR e.latitude IS NULL OR e.longitude IS NULL THEN NULL
        ELSE extensions.earth_distance(
          extensions.ll_to_earth(p_lat, p_lng),
          extensions.ll_to_earth(e.latitude, e.longitude)
        ) / 1000.0
      END AS distance_km,
      CASE
        WHEN p_lat IS NULL OR p_lng IS NULL OR e.latitude IS NULL OR e.longitude IS NULL THEN 0.50
        ELSE GREATEST(
          0.0,
          1.0 - (
            extensions.earth_distance(
              extensions.ll_to_earth(p_lat, p_lng),
              extensions.ll_to_earth(e.latitude, e.longitude)
            ) / 1000.0
          ) / 50.0
        )
      END AS distance_score,
      CASE
        WHEN e.is_outdoor IS NULL THEN 0.50
        WHEN p_weather_fit = 'outdoor' AND e.is_outdoor THEN 1.0
        WHEN p_weather_fit = 'indoor' AND NOT e.is_outdoor THEN 1.0
        WHEN p_weather_fit = 'outdoor' AND NOT e.is_outdoor THEN 0.20
        WHEN p_weather_fit = 'indoor' AND e.is_outdoor THEN 0.20
        ELSE 0.60
      END AS weather_score,
      CASE
        WHEN p_kid_age IS NULL THEN 0.50
        WHEN COALESCE(e.age_min, 0) <= p_kid_age AND COALESCE(e.age_max, 99) >= p_kid_age THEN 1.0
        ELSE GREATEST(
          0.0,
          1.0 - LEAST(
            ABS(COALESCE(e.age_min, p_kid_age) - p_kid_age),
            ABS(COALESCE(e.age_max, p_kid_age) - p_kid_age)
          )::numeric / 5.0
        )
      END AS age_score,
      CASE
        WHEN eh.tag_count IS NULL OR eh.tag_count = 0 THEN 0.0
        ELSE eh.matching_tag_count / eh.tag_count
      END AS history_affinity
    FROM candidate_events e
    LEFT JOIN event_history eh ON eh.event_id = e.id
  )
  SELECT
    se.event_id,
    (se.distance_score * 0.40
     + se.weather_score * 0.25
     + se.age_score * 0.20
     + se.history_affinity * 0.15)::numeric AS score,
    se.distance_score::numeric,
    se.weather_score::numeric,
    se.age_score::numeric,
    se.history_affinity::numeric,
    se.distance_km::numeric
  FROM scored_events se
  ORDER BY score DESC
  LIMIT p_limit;
END;
$$;


ALTER FUNCTION "public"."plan_events_for_user"("p_user_id" "uuid", "p_date" "date", "p_city_id" "uuid", "p_lat" double precision, "p_lng" double precision, "p_kid_age" integer, "p_weather_fit" "text", "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_role_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  IF NEW.role IS DISTINCT FROM OLD.role THEN
    IF auth.uid() IS NULL THEN
      RETURN NEW;
    END IF;
    IF NOT private.is_admin() THEN
      RAISE EXCEPTION 'Only admins can change user_profiles.role' USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."prevent_role_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reap_stuck_source_scrape_queue_rows"() RETURNS integer
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$ SELECT private.reap_stuck_source_scrape_queue_rows(); $$;


ALTER FUNCTION "public"."reap_stuck_source_scrape_queue_rows"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reap_stuck_tag_queue_rows"() RETURNS integer
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$ SELECT private.reap_stuck_tag_queue_rows(); $$;


ALTER FUNCTION "public"."reap_stuck_tag_queue_rows"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."redeem_invite"("p_code" "text") RETURNS boolean
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$ SELECT private.redeem_invite(p_code); $$;


ALTER FUNCTION "public"."redeem_invite"("p_code" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."redeem_invite_for_email"("p_code" "text", "p_email" "text") RETURNS boolean
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$ SELECT private.redeem_invite_for_email(p_code, p_email); $$;


ALTER FUNCTION "public"."redeem_invite_for_email"("p_code" "text", "p_email" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."release_unstarted_source_scrape_queue_rows"("p_claimed_ids" bigint[]) RETURNS integer
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$ SELECT private.release_unstarted_source_scrape_queue_rows(p_claimed_ids); $$;


ALTER FUNCTION "public"."release_unstarted_source_scrape_queue_rows"("p_claimed_ids" bigint[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."release_unstarted_tag_queue_rows"("p_claimed_ids" bigint[]) RETURNS integer
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$ SELECT private.release_unstarted_tag_queue_rows(p_claimed_ids); $$;


ALTER FUNCTION "public"."release_unstarted_tag_queue_rows"("p_claimed_ids" bigint[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."request_invite"("p_email" "text", "p_message" "text" DEFAULT NULL::"text") RETURNS boolean
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$ SELECT private.request_invite(p_email, p_message); $$;


ALTER FUNCTION "public"."request_invite"("p_email" "text", "p_message" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reset_comment_approval_for_non_admin"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  IF NEW.is_approved IS DISTINCT FROM OLD.is_approved THEN
    IF auth.uid() IS NOT NULL AND NOT private.is_admin() THEN
      NEW.is_approved := OLD.is_approved;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."reset_comment_approval_for_non_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."run_cleanup_stale_runs"() RETURNS "void"
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
  SELECT private.cleanup_stale_source_runs();
$$;


ALTER FUNCTION "public"."run_cleanup_stale_runs"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."run_cleanup_stale_runs"() IS 'Reaps source_runs stuck in ''running'' >15 min and propagates to event_sources. Invoked by the cron-cleanup-stale Railway service via the cleanup-stale-runs edge function every 30 min. Replaces the pg_cron job of the same cadence.';



CREATE OR REPLACE FUNCTION "public"."run_daily_maintenance"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_event_tag_pruned         int;
  v_invite_request_pruned    int;
  v_invite_redemption_pruned int;
  v_rec_pruned               int;
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

  -- Refresh the timezone names materialized view cache. Cheap + idempotent.
  -- Previously scheduled weekly via pg_cron; folded here to drop the
  -- separate cron entry.
  PERFORM private.refresh_timezone_names();

  RETURN jsonb_build_object(
    'event_tag_queue_pruned',            v_event_tag_pruned,
    'invite_request_attempts_pruned',    v_invite_request_pruned,
    'invite_redemption_attempts_pruned', v_invite_redemption_pruned,
    'recommendation_signals_pruned',     v_rec_pruned,
    'timezone_names_refreshed',          true,
    'ran_at',                            now()
  );
END;
$$;


ALTER FUNCTION "public"."run_daily_maintenance"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."run_daily_maintenance"() IS 'Daily prune: event_tag_queue dead/failed, invite_request_attempts, invite_redemption_attempts, recommendation_signals. Also refreshes private.timezone_names_cache (folded in from the unscheduled refresh-timezone-names pg_cron job). Invoked by cron-db-maintenance Railway service via the db-maintenance edge function.';



CREATE OR REPLACE FUNCTION "public"."run_due_source_scrapes"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_enqueued int := 0;
BEGIN
  INSERT INTO public.source_scrape_queue (source_id, trigger_type)
  SELECT s.id, 'scheduled'
  FROM public.event_sources s
  WHERE s.is_active = true
    AND (
      s.last_scraped_at IS NULL
      OR s.last_scraped_at + make_interval(hours => s.scrape_interval_hours) <= now()
    )
  ON CONFLICT DO NOTHING;

  GET DIAGNOSTICS v_enqueued = ROW_COUNT;
END;
$$;


ALTER FUNCTION "public"."run_due_source_scrapes"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."search_events"("p_city_id" "uuid" DEFAULT NULL::"uuid", "p_date_from" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_date_to" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_age_min" integer DEFAULT NULL::integer, "p_age_max" integer DEFAULT NULL::integer, "p_is_free" boolean DEFAULT NULL::boolean, "p_is_featured" boolean DEFAULT NULL::boolean, "p_tag_slugs" "text"[] DEFAULT NULL::"text"[], "p_keyword" "text" DEFAULT NULL::"text", "p_status" "text" DEFAULT 'published'::"text", "p_limit" integer DEFAULT 100, "p_offset" integer DEFAULT 0) RETURNS SETOF "public"."events"
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
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


ALTER FUNCTION "public"."search_events"("p_city_id" "uuid", "p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone, "p_age_min" integer, "p_age_max" integer, "p_is_free" boolean, "p_is_featured" boolean, "p_tag_slugs" "text"[], "p_keyword" "text", "p_status" "text", "p_limit" integer, "p_offset" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."source_scrape_queue_schedule_retry"("p_queue_id" bigint, "p_attempt_count" integer, "p_error" "text") RETURNS "void"
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$ SELECT private.source_scrape_queue_schedule_retry(p_queue_id, p_attempt_count, p_error); $$;


ALTER FUNCTION "public"."source_scrape_queue_schedule_retry"("p_queue_id" bigint, "p_attempt_count" integer, "p_error" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_event_search_vector"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  NEW.search_vector := to_tsvector(
    'pg_catalog.english'::regconfig,
    coalesce(NEW.title, '') || ' ' ||
    coalesce(NEW.description, '') || ' ' ||
    coalesce(NEW.venue_name, '') || ' ' ||
    coalesce(NEW.address, '')
  );
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_event_search_vector"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "private"."railway_cron_runs" (
    "id" bigint NOT NULL,
    "label" "text" NOT NULL,
    "status" "text" NOT NULL,
    "http_status" integer,
    "duration_s" integer,
    "body" "text",
    "ran_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "railway_cron_runs_status_check" CHECK (("status" = ANY (ARRAY['succeeded'::"text", 'failed'::"text"])))
);


ALTER TABLE "private"."railway_cron_runs" OWNER TO "postgres";


ALTER TABLE "private"."railway_cron_runs" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "private"."railway_cron_runs_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE MATERIALIZED VIEW "private"."timezone_names_cache" AS
 SELECT "name"
   FROM "pg_timezone_names"
  ORDER BY "name"
  WITH NO DATA;


ALTER MATERIALIZED VIEW "private"."timezone_names_cache" OWNER TO "postgres";


COMMENT ON MATERIALIZED VIEW "private"."timezone_names_cache" IS 'Cached snapshot of pg_timezone_names. Refreshed weekly by the
   refresh-timezone-names cron. Read by frontend tz pickers to avoid the
   ~440ms cost of touching pg_timezone_names on every dropdown render.';



CREATE TABLE IF NOT EXISTS "public"."admin_audit_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "admin_user_id" "uuid",
    "action" "text" NOT NULL,
    "target_type" "text",
    "target_id" "uuid",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."admin_audit_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cities" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "state" "text",
    "country" "text" DEFAULT 'US'::"text" NOT NULL,
    "slug" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "latitude" numeric(10,7),
    "longitude" numeric(10,7),
    "timezone" "text" DEFAULT 'America/Chicago'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."cities" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."comments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "event_id" "uuid" NOT NULL,
    "body" "text" NOT NULL,
    "is_approved" boolean DEFAULT true NOT NULL,
    "is_flagged" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "comments_body_len_chk" CHECK ((("length"("body") >= 1) AND ("length"("body") <= 4000)))
);

ALTER TABLE ONLY "public"."comments" REPLICA IDENTITY FULL;


ALTER TABLE "public"."comments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_ai_traces" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "source_run_id" "uuid",
    "trigger_type" "text" DEFAULT 'import'::"text" NOT NULL,
    "provider" "text",
    "model" "text",
    "status" "text" DEFAULT 'success'::"text" NOT NULL,
    "input_title" "text" NOT NULL,
    "input_description" "text",
    "available_tag_slugs" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "predicted_tags" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "predicted_fields" "jsonb",
    "reasoning_summary" "text",
    "fallback_reason" "text",
    "processing_ms" integer,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "event_ai_traces_provider_check" CHECK ((("provider" IS NULL) OR ("provider" = ANY (ARRAY['openai'::"text", 'ollama'::"text", 'localai'::"text"])))),
    CONSTRAINT "event_ai_traces_status_check" CHECK (("status" = ANY (ARRAY['success'::"text", 'fallback'::"text", 'error'::"text"]))),
    CONSTRAINT "event_ai_traces_trigger_type_check" CHECK (("trigger_type" = ANY (ARRAY['import'::"text", 'reclassify'::"text", 'manual-review'::"text"])))
);


ALTER TABLE "public"."event_ai_traces" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ratings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "event_id" "uuid" NOT NULL,
    "score" integer NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "ratings_score_check" CHECK ((("score" >= 1) AND ("score" <= 5)))
);


ALTER TABLE "public"."ratings" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."event_rating_stats" WITH ("security_invoker"='true') AS
 SELECT "event_id",
    "round"("avg"("score"), 1) AS "avg_score",
    ("count"(*))::integer AS "rating_count"
   FROM "public"."ratings"
  GROUP BY "event_id";


ALTER VIEW "public"."event_rating_stats" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_sources" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "url" "text" NOT NULL,
    "source_type" "text" DEFAULT 'website'::"text" NOT NULL,
    "city_id" "uuid",
    "is_active" boolean DEFAULT true NOT NULL,
    "scrape_interval_hours" integer DEFAULT 24 NOT NULL,
    "last_scraped_at" timestamp with time zone,
    "last_status" "text" DEFAULT 'pending'::"text",
    "error_count" integer DEFAULT 0 NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "auto_approve" boolean DEFAULT false NOT NULL,
    "date_window_days" integer,
    "extraction_mode" "public"."source_extraction_mode" DEFAULT 'deterministic'::"public"."source_extraction_mode" NOT NULL,
    CONSTRAINT "event_sources_last_status_check" CHECK (("last_status" = ANY (ARRAY['pending'::"text", 'success'::"text", 'error'::"text", 'partial'::"text"]))),
    CONSTRAINT "event_sources_source_type_check" CHECK (("source_type" = ANY (ARRAY['website'::"text", 'ical'::"text", 'rss'::"text", 'manual'::"text", 'macaronikid'::"text", 'brec'::"text"])))
);


ALTER TABLE "public"."event_sources" OWNER TO "postgres";


ALTER TABLE "public"."event_tag_queue" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."event_tag_queue_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE OR REPLACE VIEW "public"."event_tag_queue_summary" WITH ("security_invoker"='true') AS
 SELECT "status",
    ("count"(*))::integer AS "row_count",
    "min"("enqueued_at") AS "oldest_enqueued_at",
    "max"("enqueued_at") AS "newest_enqueued_at",
    "max"("finished_at") FILTER (WHERE ("status" = 'dead'::"public"."event_tag_queue_status")) AS "last_dead_letter_at",
    ("avg"("attempt_count") FILTER (WHERE ("status" <> 'pending'::"public"."event_tag_queue_status")))::numeric(10,2) AS "avg_attempts"
   FROM "public"."event_tag_queue"
  GROUP BY "status";


ALTER VIEW "public"."event_tag_queue_summary" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_tags" (
    "event_id" "uuid" NOT NULL,
    "tag_id" "uuid" NOT NULL,
    "confidence" numeric(4,3) DEFAULT 1.0 NOT NULL,
    "is_manual_override" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."event_tags" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."favorites" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "event_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."favorites" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."invite_codes" (
    "max_uses" integer DEFAULT 1 NOT NULL,
    "used_count" integer DEFAULT 0 NOT NULL,
    "expires_at" timestamp with time zone,
    "notes" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "code_hash" "text" NOT NULL,
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "revoked_at" timestamp with time zone,
    CONSTRAINT "invite_codes_code_hash_len_chk" CHECK (("length"("code_hash") = 64)),
    CONSTRAINT "invite_codes_max_uses_check" CHECK (("max_uses" > 0)),
    CONSTRAINT "invite_codes_used_count_check" CHECK (("used_count" >= 0))
);

ALTER TABLE ONLY "public"."invite_codes" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."invite_codes" OWNER TO "postgres";


COMMENT ON TABLE "public"."invite_codes" IS 'Invite codes are stored as sha256 hashes only. Plaintext is visible to the
   admin once at creation time via admin_create_invite_code RPC, never afterward.';



COMMENT ON COLUMN "public"."invite_codes"."revoked_at" IS 'When non-null, the row is revoked and cannot be redeemed. Set via
   admin_revoke_invite_code RPC; once set it is one-way.';



CREATE TABLE IF NOT EXISTS "public"."invite_redemption_attempts" (
    "id" bigint NOT NULL,
    "email_hash" "text" NOT NULL,
    "attempted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "succeeded" boolean NOT NULL
);

ALTER TABLE ONLY "public"."invite_redemption_attempts" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."invite_redemption_attempts" OWNER TO "postgres";


ALTER TABLE "public"."invite_redemption_attempts" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."invite_redemption_attempts_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."invite_request_attempts" (
    "id" bigint NOT NULL,
    "email_hash" "text" NOT NULL,
    "attempted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "succeeded" boolean NOT NULL
);

ALTER TABLE ONLY "public"."invite_request_attempts" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."invite_request_attempts" OWNER TO "postgres";


ALTER TABLE "public"."invite_request_attempts" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."invite_request_attempts_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."invite_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "email" "text" NOT NULL,
    "message" "text",
    "status" "public"."invite_request_status" DEFAULT 'pending'::"public"."invite_request_status" NOT NULL,
    "invite_code_id" "uuid",
    "admin_notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reviewed_at" timestamp with time zone,
    "reviewed_by" "uuid",
    CONSTRAINT "invite_requests_admin_notes_len_chk" CHECK ((("admin_notes" IS NULL) OR ("length"("admin_notes") <= 1000))),
    CONSTRAINT "invite_requests_email_len_chk" CHECK ((("length"("email") >= 3) AND ("length"("email") <= 320))),
    CONSTRAINT "invite_requests_message_len_chk" CHECK ((("message" IS NULL) OR ("length"("message") <= 500)))
);

ALTER TABLE ONLY "public"."invite_requests" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."invite_requests" OWNER TO "postgres";


COMMENT ON TABLE "public"."invite_requests" IS 'Anon-submitted invite requests. Admin approval generates an invite_codes
   row and links it via invite_code_id, then the admin shares the plaintext
   out-of-band.';



CREATE TABLE IF NOT EXISTS "public"."pending_invite_claims" (
    "email" "text" NOT NULL,
    "invite_code" "text" NOT NULL,
    "expires_at" timestamp with time zone DEFAULT ("now"() + '02:00:00'::interval) NOT NULL,
    "claimed_by" "uuid",
    "claimed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE ONLY "public"."pending_invite_claims" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."pending_invite_claims" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."public_events" WITH ("security_invoker"='true') AS
 SELECT "id",
    "title",
    "description",
    "start_datetime",
    "end_datetime",
    "timezone",
    "venue_name",
    "address",
    "city_id",
    "latitude",
    "longitude",
    "age_min",
    "age_max",
    "price",
    "is_free",
    "source_url",
    "source_name",
    "images",
    "recurrence_info",
    "is_featured"
   FROM "public"."events" "e"
  WHERE ("status" = 'published'::"text");


ALTER VIEW "public"."public_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."recommendation_signals" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "event_id" "uuid" NOT NULL,
    "signal_type" "text" NOT NULL,
    "weight" numeric(4,2) DEFAULT 1.0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "recommendation_signals_signal_type_check" CHECK (("signal_type" = ANY (ARRAY['view'::"text", 'favorite'::"text", 'calendar'::"text", 'rate'::"text", 'comment'::"text"])))
);


ALTER TABLE "public"."recommendation_signals" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."source_extraction_traces" (
    "id" bigint NOT NULL,
    "source_queue_id" bigint,
    "source_run_id" "uuid",
    "source_id" "uuid",
    "extraction_mode" "public"."source_extraction_mode" NOT NULL,
    "extractor" "text" NOT NULL,
    "provider" "text",
    "model" "text",
    "status" "text" NOT NULL,
    "input_bytes" integer,
    "parsed_event_count" integer DEFAULT 0 NOT NULL,
    "fallback_reason" "text",
    "latency_ms" integer,
    "reasoning_summary" "text",
    "error" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "source_extraction_traces_extractor_check" CHECK (("extractor" = ANY (ARRAY['deterministic'::"text", 'llm'::"text"]))),
    CONSTRAINT "source_extraction_traces_status_check" CHECK (("status" = ANY (ARRAY['success'::"text", 'fallback'::"text", 'error'::"text"])))
);

ALTER TABLE ONLY "public"."source_extraction_traces" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."source_extraction_traces" OWNER TO "postgres";


ALTER TABLE "public"."source_extraction_traces" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."source_extraction_traces_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."source_runs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "source_id" "uuid",
    "started_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "completed_at" timestamp with time zone,
    "status" "text" DEFAULT 'running'::"text" NOT NULL,
    "events_found" integer DEFAULT 0 NOT NULL,
    "events_imported" integer DEFAULT 0 NOT NULL,
    "events_skipped" integer DEFAULT 0 NOT NULL,
    "error_log" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "source_runs_status_check" CHECK (("status" = ANY (ARRAY['running'::"text", 'success'::"text", 'error'::"text", 'partial'::"text"])))
);


ALTER TABLE "public"."source_runs" OWNER TO "postgres";


ALTER TABLE "public"."source_scrape_queue" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."source_scrape_queue_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE OR REPLACE VIEW "public"."source_scrape_queue_summary" WITH ("security_invoker"='true') AS
 SELECT "status",
    ("count"(*))::integer AS "row_count",
    "min"("enqueued_at") AS "oldest_enqueued_at",
    "min"("started_at") FILTER (WHERE ("status" = 'processing'::"public"."source_scrape_queue_status")) AS "oldest_processing_started_at",
    "max"("finished_at") AS "newest_finished_at",
    "max"("finished_at") FILTER (WHERE ("status" = 'dead'::"public"."source_scrape_queue_status")) AS "last_dead_letter_at",
    ("avg"("attempt_count"))::numeric(10,2) AS "avg_attempts"
   FROM "public"."source_scrape_queue"
  GROUP BY "status";


ALTER VIEW "public"."source_scrape_queue_summary" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tags" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "slug" "text" NOT NULL,
    "color" "text" DEFAULT '#6b7280'::"text" NOT NULL,
    "category" "text" DEFAULT 'theme'::"text" NOT NULL,
    "is_system" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."tags" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."timezone_names" WITH ("security_invoker"='true') AS
 SELECT "name"
   FROM "private"."timezone_names_cache";


ALTER VIEW "public"."timezone_names" OWNER TO "postgres";


COMMENT ON VIEW "public"."timezone_names" IS 'Read-only passthrough of private.timezone_names_cache. Hides the
   underlying materialized view from the Data API (advisor lint 0016)
   while preserving the public.timezone_names interface used by the
   admin timezone dropdown.';



CREATE TABLE IF NOT EXISTS "public"."user_access" (
    "user_id" "uuid" NOT NULL,
    "is_enabled" boolean DEFAULT false NOT NULL,
    "access_expires_at" timestamp with time zone,
    "enabled_at" timestamp with time zone,
    "disabled_at" timestamp with time zone,
    "disabled_reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE ONLY "public"."user_access" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_access" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_calendar_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "event_id" "uuid" NOT NULL,
    "added_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "notes" "text"
);


ALTER TABLE "public"."user_calendar_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_profiles" (
    "id" "uuid" NOT NULL,
    "email" "text",
    "display_name" "text",
    "avatar_url" "text",
    "role" "text" DEFAULT 'user'::"text" NOT NULL,
    "city_preference_id" "uuid",
    "child_name" "text",
    "child_age" integer,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "user_profiles_role_check" CHECK (("role" = ANY (ARRAY['user'::"text", 'admin'::"text"])))
);

ALTER TABLE ONLY "public"."user_profiles" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_profiles" OWNER TO "postgres";


ALTER TABLE ONLY "private"."railway_cron_runs"
    ADD CONSTRAINT "railway_cron_runs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."admin_audit_log"
    ADD CONSTRAINT "admin_audit_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cities"
    ADD CONSTRAINT "cities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cities"
    ADD CONSTRAINT "cities_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_ai_traces"
    ADD CONSTRAINT "event_ai_traces_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_sources"
    ADD CONSTRAINT "event_sources_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_sources"
    ADD CONSTRAINT "event_sources_url_key" UNIQUE ("url");



ALTER TABLE ONLY "public"."event_tag_queue"
    ADD CONSTRAINT "event_tag_queue_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_tags"
    ADD CONSTRAINT "event_tags_pkey" PRIMARY KEY ("event_id", "tag_id");



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."favorites"
    ADD CONSTRAINT "favorites_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."favorites"
    ADD CONSTRAINT "favorites_user_id_event_id_key" UNIQUE ("user_id", "event_id");



ALTER TABLE ONLY "public"."invite_codes"
    ADD CONSTRAINT "invite_codes_code_hash_uniq" UNIQUE ("code_hash");



ALTER TABLE ONLY "public"."invite_codes"
    ADD CONSTRAINT "invite_codes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."invite_redemption_attempts"
    ADD CONSTRAINT "invite_redemption_attempts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."invite_request_attempts"
    ADD CONSTRAINT "invite_request_attempts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."invite_requests"
    ADD CONSTRAINT "invite_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pending_invite_claims"
    ADD CONSTRAINT "pending_invite_claims_pkey" PRIMARY KEY ("email");



ALTER TABLE ONLY "public"."ratings"
    ADD CONSTRAINT "ratings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ratings"
    ADD CONSTRAINT "ratings_user_id_event_id_key" UNIQUE ("user_id", "event_id");



ALTER TABLE ONLY "public"."recommendation_signals"
    ADD CONSTRAINT "recommendation_signals_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."source_extraction_traces"
    ADD CONSTRAINT "source_extraction_traces_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."source_runs"
    ADD CONSTRAINT "source_runs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."source_scrape_queue"
    ADD CONSTRAINT "source_scrape_queue_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tags"
    ADD CONSTRAINT "tags_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."tags"
    ADD CONSTRAINT "tags_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tags"
    ADD CONSTRAINT "tags_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."user_access"
    ADD CONSTRAINT "user_access_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."user_calendar_events"
    ADD CONSTRAINT "user_calendar_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_calendar_events"
    ADD CONSTRAINT "user_calendar_events_user_id_event_id_key" UNIQUE ("user_id", "event_id");



ALTER TABLE ONLY "public"."user_profiles"
    ADD CONSTRAINT "user_profiles_pkey" PRIMARY KEY ("id");



CREATE INDEX "railway_cron_runs_label_ran_at" ON "private"."railway_cron_runs" USING "btree" ("label", "ran_at" DESC);



CREATE UNIQUE INDEX "timezone_names_cache_name_uidx" ON "private"."timezone_names_cache" USING "btree" ("name");



CREATE INDEX "admin_audit_log_admin_user_id_idx" ON "public"."admin_audit_log" USING "btree" ("admin_user_id");



CREATE INDEX "admin_audit_log_metadata_idx" ON "public"."admin_audit_log" USING "gin" ("metadata");



CREATE INDEX "comments_approved_event_created_at_idx" ON "public"."comments" USING "btree" ("event_id", "created_at" DESC) WHERE ("is_approved" = true);



CREATE INDEX "comments_event_id_idx" ON "public"."comments" USING "btree" ("event_id");



CREATE INDEX "comments_user_id_idx" ON "public"."comments" USING "btree" ("user_id");



CREATE INDEX "event_ai_traces_event_id_created_at_idx" ON "public"."event_ai_traces" USING "btree" ("event_id", "created_at" DESC);



CREATE INDEX "event_ai_traces_source_run_id_idx" ON "public"."event_ai_traces" USING "btree" ("source_run_id") WHERE ("source_run_id" IS NOT NULL);



CREATE INDEX "event_sources_city_id_idx" ON "public"."event_sources" USING "btree" ("city_id");



CREATE INDEX "event_tag_queue_claimable_idx" ON "public"."event_tag_queue" USING "btree" ("next_attempt_at") WHERE ("status" = 'pending'::"public"."event_tag_queue_status");



CREATE UNIQUE INDEX "event_tag_queue_event_active_uniq" ON "public"."event_tag_queue" USING "btree" ("event_id") WHERE ("status" = ANY (ARRAY['pending'::"public"."event_tag_queue_status", 'processing'::"public"."event_tag_queue_status"]));



CREATE INDEX "event_tag_queue_source_run_id_idx" ON "public"."event_tag_queue" USING "btree" ("source_run_id");



CREATE INDEX "event_tag_queue_status_idx" ON "public"."event_tag_queue" USING "btree" ("status", "enqueued_at" DESC);



CREATE INDEX "event_tags_tag_id_idx" ON "public"."event_tags" USING "btree" ("tag_id");



CREATE INDEX "events_admin_last_edited_at_idx" ON "public"."events" USING "btree" ("admin_last_edited_at") WHERE ("admin_last_edited_at" IS NOT NULL);



CREATE INDEX "events_admin_last_edited_by_idx" ON "public"."events" USING "btree" ("admin_last_edited_by") WHERE ("admin_last_edited_by" IS NOT NULL);



CREATE INDEX "events_city_id_idx" ON "public"."events" USING "btree" ("city_id");



CREATE INDEX "events_city_id_start_datetime_idx" ON "public"."events" USING "btree" ("city_id", "start_datetime");



CREATE INDEX "events_is_featured_idx" ON "public"."events" USING "btree" ("is_featured");



CREATE INDEX "events_local_date_published_idx" ON "public"."events" USING "btree" (((("start_datetime" AT TIME ZONE "timezone"))::"date")) WHERE ("status" = 'published'::"text");



COMMENT ON INDEX "public"."events_local_date_published_idx" IS 'Supports plan_events_for_user candidate_events filter on
   (start_datetime AT TIME ZONE timezone)::date for published events.
   Partial keeps the index small — drafts/archived rows are never read by
   the planner RPC.';



CREATE INDEX "events_published_city_start_datetime_idx" ON "public"."events" USING "btree" ("city_id", "start_datetime") WHERE ("status" = 'published'::"text");



CREATE INDEX "events_search_vector_idx" ON "public"."events" USING "gin" ("search_vector");



CREATE INDEX "events_source_id_idx" ON "public"."events" USING "btree" ("source_id");



CREATE UNIQUE INDEX "events_source_id_source_url_uniq" ON "public"."events" USING "btree" ("source_id", "source_url") WHERE ("source_url" IS NOT NULL);



COMMENT ON INDEX "public"."events_source_id_source_url_uniq" IS 'Idempotency for scrape-source imports. Backs upsert(... onConflict source_id,source_url).';



CREATE INDEX "events_start_datetime_idx" ON "public"."events" USING "btree" ("start_datetime");



CREATE INDEX "events_status_idx" ON "public"."events" USING "btree" ("status");



CREATE INDEX "events_status_start_datetime_idx" ON "public"."events" USING "btree" ("status", "start_datetime");



CREATE INDEX "favorites_event_id_idx" ON "public"."favorites" USING "btree" ("event_id");



CREATE INDEX "favorites_user_id_idx" ON "public"."favorites" USING "btree" ("user_id");



CREATE INDEX "idx_events_ai_tag_provider" ON "public"."events" USING "btree" ("ai_tag_provider") WHERE ("ai_tag_provider" IS NOT NULL);



CREATE INDEX "idx_events_ai_tag_status" ON "public"."events" USING "btree" ("ai_tag_status") WHERE ("ai_tag_status" IS NOT NULL);



CREATE INDEX "invite_codes_created_by_idx" ON "public"."invite_codes" USING "btree" ("created_by");



CREATE INDEX "invite_redemption_attempts_email_hash_idx" ON "public"."invite_redemption_attempts" USING "btree" ("email_hash", "attempted_at" DESC);



CREATE INDEX "invite_request_attempts_email_hash_idx" ON "public"."invite_request_attempts" USING "btree" ("email_hash", "attempted_at" DESC);



CREATE UNIQUE INDEX "invite_requests_email_pending_uniq" ON "public"."invite_requests" USING "btree" ("lower"("email")) WHERE ("status" = 'pending'::"public"."invite_request_status");



CREATE INDEX "invite_requests_invite_code_id_idx" ON "public"."invite_requests" USING "btree" ("invite_code_id");



CREATE INDEX "invite_requests_reviewed_by_idx" ON "public"."invite_requests" USING "btree" ("reviewed_by");



CREATE INDEX "invite_requests_status_created_idx" ON "public"."invite_requests" USING "btree" ("status", "created_at" DESC);



CREATE INDEX "pending_invite_claims_claimed_by_idx" ON "public"."pending_invite_claims" USING "btree" ("claimed_by");



CREATE INDEX "pending_invite_claims_invite_code_idx" ON "public"."pending_invite_claims" USING "btree" ("invite_code");



CREATE INDEX "ratings_event_id_idx" ON "public"."ratings" USING "btree" ("event_id");



CREATE INDEX "recommendation_signals_event_id_idx" ON "public"."recommendation_signals" USING "btree" ("event_id");



CREATE INDEX "recommendation_signals_user_created_idx" ON "public"."recommendation_signals" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "recommendation_signals_user_id_idx" ON "public"."recommendation_signals" USING "btree" ("user_id");



CREATE INDEX "source_extraction_traces_source_id_idx" ON "public"."source_extraction_traces" USING "btree" ("source_id") WHERE ("source_id" IS NOT NULL);



CREATE INDEX "source_extraction_traces_source_queue_id_idx" ON "public"."source_extraction_traces" USING "btree" ("source_queue_id") WHERE ("source_queue_id" IS NOT NULL);



CREATE INDEX "source_extraction_traces_source_run_idx" ON "public"."source_extraction_traces" USING "btree" ("source_run_id", "created_at" DESC) WHERE ("source_run_id" IS NOT NULL);



CREATE INDEX "source_runs_source_id_idx" ON "public"."source_runs" USING "btree" ("source_id");



CREATE INDEX "source_scrape_queue_claimable_idx" ON "public"."source_scrape_queue" USING "btree" ("next_attempt_at", "id") WHERE ("status" = ANY (ARRAY['pending'::"public"."source_scrape_queue_status", 'retrying'::"public"."source_scrape_queue_status"]));



CREATE UNIQUE INDEX "source_scrape_queue_source_active_uniq" ON "public"."source_scrape_queue" USING "btree" ("source_id") WHERE (("source_id" IS NOT NULL) AND ("status" = ANY (ARRAY['pending'::"public"."source_scrape_queue_status", 'processing'::"public"."source_scrape_queue_status", 'retrying'::"public"."source_scrape_queue_status"])));



CREATE INDEX "source_scrape_queue_source_run_id_idx" ON "public"."source_scrape_queue" USING "btree" ("source_run_id") WHERE ("source_run_id" IS NOT NULL);



CREATE INDEX "source_scrape_queue_status_idx" ON "public"."source_scrape_queue" USING "btree" ("status", "enqueued_at" DESC);



CREATE INDEX "user_calendar_events_event_id_idx" ON "public"."user_calendar_events" USING "btree" ("event_id");



CREATE INDEX "user_calendar_events_user_id_idx" ON "public"."user_calendar_events" USING "btree" ("user_id");



CREATE INDEX "user_profiles_city_preference_id_idx" ON "public"."user_profiles" USING "btree" ("city_preference_id");



CREATE OR REPLACE TRIGGER "events_search_vector_trigger" BEFORE INSERT OR UPDATE ON "public"."events" FOR EACH ROW EXECUTE FUNCTION "public"."update_event_search_vector"();



CREATE OR REPLACE TRIGGER "prevent_role_change_on_profile" BEFORE UPDATE ON "public"."user_profiles" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_role_change"();



CREATE OR REPLACE TRIGGER "reset_comment_approval_on_update" BEFORE UPDATE ON "public"."comments" FOR EACH ROW EXECUTE FUNCTION "public"."reset_comment_approval_for_non_admin"();



CREATE OR REPLACE TRIGGER "user_access_audit_timestamps" BEFORE INSERT OR UPDATE OF "is_enabled" ON "public"."user_access" FOR EACH ROW EXECUTE FUNCTION "private"."user_access_set_audit_timestamps"();



ALTER TABLE ONLY "public"."admin_audit_log"
    ADD CONSTRAINT "admin_audit_log_admin_user_id_fkey" FOREIGN KEY ("admin_user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user_profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_ai_traces"
    ADD CONSTRAINT "event_ai_traces_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_ai_traces"
    ADD CONSTRAINT "event_ai_traces_source_run_id_fkey" FOREIGN KEY ("source_run_id") REFERENCES "public"."source_runs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."event_sources"
    ADD CONSTRAINT "event_sources_city_id_fkey" FOREIGN KEY ("city_id") REFERENCES "public"."cities"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."event_tag_queue"
    ADD CONSTRAINT "event_tag_queue_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_tag_queue"
    ADD CONSTRAINT "event_tag_queue_source_run_id_fkey" FOREIGN KEY ("source_run_id") REFERENCES "public"."source_runs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."event_tags"
    ADD CONSTRAINT "event_tags_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_tags"
    ADD CONSTRAINT "event_tags_tag_id_fkey" FOREIGN KEY ("tag_id") REFERENCES "public"."tags"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_admin_last_edited_by_fkey" FOREIGN KEY ("admin_last_edited_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_city_id_fkey" FOREIGN KEY ("city_id") REFERENCES "public"."cities"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_source_id_fkey" FOREIGN KEY ("source_id") REFERENCES "public"."event_sources"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."favorites"
    ADD CONSTRAINT "favorites_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."favorites"
    ADD CONSTRAINT "favorites_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user_profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."invite_codes"
    ADD CONSTRAINT "invite_codes_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."user_profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."invite_requests"
    ADD CONSTRAINT "invite_requests_invite_code_id_fkey" FOREIGN KEY ("invite_code_id") REFERENCES "public"."invite_codes"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."invite_requests"
    ADD CONSTRAINT "invite_requests_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "public"."user_profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."pending_invite_claims"
    ADD CONSTRAINT "pending_invite_claims_claimed_by_fkey" FOREIGN KEY ("claimed_by") REFERENCES "public"."user_profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ratings"
    ADD CONSTRAINT "ratings_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ratings"
    ADD CONSTRAINT "ratings_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user_profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."recommendation_signals"
    ADD CONSTRAINT "recommendation_signals_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."recommendation_signals"
    ADD CONSTRAINT "recommendation_signals_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user_profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."source_extraction_traces"
    ADD CONSTRAINT "source_extraction_traces_source_id_fkey" FOREIGN KEY ("source_id") REFERENCES "public"."event_sources"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."source_extraction_traces"
    ADD CONSTRAINT "source_extraction_traces_source_queue_id_fkey" FOREIGN KEY ("source_queue_id") REFERENCES "public"."source_scrape_queue"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."source_extraction_traces"
    ADD CONSTRAINT "source_extraction_traces_source_run_id_fkey" FOREIGN KEY ("source_run_id") REFERENCES "public"."source_runs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."source_runs"
    ADD CONSTRAINT "source_runs_source_id_fkey" FOREIGN KEY ("source_id") REFERENCES "public"."event_sources"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."source_scrape_queue"
    ADD CONSTRAINT "source_scrape_queue_source_id_fkey" FOREIGN KEY ("source_id") REFERENCES "public"."event_sources"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."source_scrape_queue"
    ADD CONSTRAINT "source_scrape_queue_source_run_id_fkey" FOREIGN KEY ("source_run_id") REFERENCES "public"."source_runs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."user_access"
    ADD CONSTRAINT "user_access_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user_profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_calendar_events"
    ADD CONSTRAINT "user_calendar_events_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_calendar_events"
    ADD CONSTRAINT "user_calendar_events_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user_profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_profiles"
    ADD CONSTRAINT "user_profiles_city_preference_id_fkey" FOREIGN KEY ("city_preference_id") REFERENCES "public"."cities"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."user_profiles"
    ADD CONSTRAINT "user_profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



CREATE POLICY "Admins can delete cities" ON "public"."cities" FOR DELETE TO "authenticated" USING ("private"."is_admin"());



CREATE POLICY "Admins can delete event tags" ON "public"."event_tags" FOR DELETE TO "authenticated" USING ("private"."is_admin"());



CREATE POLICY "Admins can delete events" ON "public"."events" FOR DELETE TO "authenticated" USING ("private"."is_admin"());



CREATE POLICY "Admins can delete sources" ON "public"."event_sources" FOR DELETE TO "authenticated" USING ("private"."is_admin"());



CREATE POLICY "Admins can delete tags" ON "public"."tags" FOR DELETE TO "authenticated" USING ("private"."is_admin"());



CREATE POLICY "Admins can delete user access" ON "public"."user_access" FOR DELETE TO "authenticated" USING ((( SELECT "private"."is_admin"() AS "is_admin") AND ("user_id" <> ( SELECT "auth"."uid"() AS "uid"))));



CREATE POLICY "Admins can insert audit log" ON "public"."admin_audit_log" FOR INSERT TO "authenticated" WITH CHECK ("private"."is_admin"());



CREATE POLICY "Admins can insert cities" ON "public"."cities" FOR INSERT TO "authenticated" WITH CHECK ("private"."is_admin"());



CREATE POLICY "Admins can insert event tags" ON "public"."event_tags" FOR INSERT TO "authenticated" WITH CHECK ("private"."is_admin"());



CREATE POLICY "Admins can insert events" ON "public"."events" FOR INSERT TO "authenticated" WITH CHECK ("private"."is_admin"());



CREATE POLICY "Admins can insert source runs" ON "public"."source_runs" FOR INSERT TO "authenticated" WITH CHECK ("private"."is_admin"());



CREATE POLICY "Admins can insert sources" ON "public"."event_sources" FOR INSERT TO "authenticated" WITH CHECK ("private"."is_admin"());



CREATE POLICY "Admins can insert tags" ON "public"."tags" FOR INSERT TO "authenticated" WITH CHECK ("private"."is_admin"());



CREATE POLICY "Admins can insert user access" ON "public"."user_access" FOR INSERT TO "authenticated" WITH CHECK (( SELECT "private"."is_admin"() AS "is_admin"));



CREATE POLICY "Admins can manage invite codes" ON "public"."invite_codes" TO "authenticated" USING ("private"."is_admin"()) WITH CHECK ("private"."is_admin"());



CREATE POLICY "Admins can read AI traces" ON "public"."event_ai_traces" FOR SELECT TO "authenticated" USING ("private"."is_admin"());



CREATE POLICY "Admins can read audit log" ON "public"."admin_audit_log" FOR SELECT TO "authenticated" USING ("private"."is_admin"());



CREATE POLICY "Admins can read invite redemption attempts" ON "public"."invite_redemption_attempts" FOR SELECT TO "authenticated" USING ("private"."is_admin"());



CREATE POLICY "Admins can read invite request attempts" ON "public"."invite_request_attempts" FOR SELECT TO "authenticated" USING ("private"."is_admin"());



CREATE POLICY "Admins can read invite requests" ON "public"."invite_requests" FOR SELECT TO "authenticated" USING ("private"."is_admin"());



CREATE POLICY "Admins can read source extraction traces" ON "public"."source_extraction_traces" FOR SELECT TO "authenticated" USING ("private"."is_admin"());



CREATE POLICY "Admins can read source scrape queue" ON "public"."source_scrape_queue" FOR SELECT TO "authenticated" USING ("private"."is_admin"());



CREATE POLICY "Admins can read tag queue" ON "public"."event_tag_queue" FOR SELECT TO "authenticated" USING ("private"."is_admin"());



CREATE POLICY "Admins can select source runs" ON "public"."source_runs" FOR SELECT TO "authenticated" USING ("private"."is_admin"());



CREATE POLICY "Admins can select sources" ON "public"."event_sources" FOR SELECT TO "authenticated" USING ("private"."is_admin"());



CREATE POLICY "Admins can update cities" ON "public"."cities" FOR UPDATE TO "authenticated" USING ("private"."is_admin"()) WITH CHECK ("private"."is_admin"());



CREATE POLICY "Admins can update event tags" ON "public"."event_tags" FOR UPDATE TO "authenticated" USING ("private"."is_admin"()) WITH CHECK ("private"."is_admin"());



CREATE POLICY "Admins can update events" ON "public"."events" FOR UPDATE TO "authenticated" USING ("private"."is_admin"()) WITH CHECK ("private"."is_admin"());



CREATE POLICY "Admins can update sources" ON "public"."event_sources" FOR UPDATE TO "authenticated" USING ("private"."is_admin"()) WITH CHECK ("private"."is_admin"());



CREATE POLICY "Admins can update tags" ON "public"."tags" FOR UPDATE TO "authenticated" USING ("private"."is_admin"()) WITH CHECK ("private"."is_admin"());



CREATE POLICY "Admins can update user access" ON "public"."user_access" FOR UPDATE TO "authenticated" USING (( SELECT "private"."is_admin"() AS "is_admin")) WITH CHECK ((( SELECT "private"."is_admin"() AS "is_admin") AND (("user_id" <> ( SELECT "auth"."uid"() AS "uid")) OR ("is_enabled" = true))));



CREATE POLICY "Anon can read active cities" ON "public"."cities" FOR SELECT TO "anon" USING (("is_active" = true));



CREATE POLICY "Anon can read approved comments on published events" ON "public"."comments" FOR SELECT TO "anon" USING ((("is_approved" = true) AND (EXISTS ( SELECT 1
   FROM "public"."public_events" "pe"
  WHERE ("pe"."id" = "comments"."event_id")))));



CREATE POLICY "Anon can read event tags for published events" ON "public"."event_tags" FOR SELECT TO "anon" USING ((EXISTS ( SELECT 1
   FROM "public"."public_events" "pe"
  WHERE ("pe"."id" = "event_tags"."event_id"))));



CREATE POLICY "Anon can read published events" ON "public"."events" FOR SELECT TO "anon" USING (("status" = 'published'::"text"));



CREATE POLICY "Anon can read ratings for published events" ON "public"."ratings" FOR SELECT TO "anon" USING ((EXISTS ( SELECT 1
   FROM "public"."public_events" "pe"
  WHERE ("pe"."id" = "ratings"."event_id"))));



CREATE POLICY "Anon can read tags" ON "public"."tags" FOR SELECT TO "anon" USING (true);



CREATE POLICY "Authenticated reads published or admin reads all" ON "public"."events" FOR SELECT TO "authenticated" USING ((( SELECT "private"."is_admin"() AS "is_admin") OR ("status" = 'published'::"text")));



CREATE POLICY "Authenticated users can delete own comments or admins can delet" ON "public"."comments" FOR DELETE TO "authenticated" USING ((( SELECT "private"."is_admin"() AS "is_admin") OR (( SELECT "private"."has_enabled_access"() AS "has_enabled_access") AND (( SELECT "auth"."uid"() AS "uid") = "user_id"))));



CREATE POLICY "Authenticated users can insert own comments or admins can inser" ON "public"."comments" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "private"."is_admin"() AS "is_admin") OR (( SELECT "private"."has_enabled_access"() AS "has_enabled_access") AND (( SELECT "auth"."uid"() AS "uid") = "user_id"))));



CREATE POLICY "Authenticated users can read approved comments or admins can re" ON "public"."comments" FOR SELECT TO "authenticated" USING ((( SELECT "private"."is_admin"() AS "is_admin") OR (( SELECT "private"."has_enabled_access"() AS "has_enabled_access") AND ("is_approved" = true) AND (EXISTS ( SELECT 1
   FROM "public"."events" "e"
  WHERE (("e"."id" = "comments"."event_id") AND ("e"."status" = 'published'::"text")))))));



CREATE POLICY "Authenticated users can update own comments or admins can updat" ON "public"."comments" FOR UPDATE TO "authenticated" USING ((( SELECT "private"."is_admin"() AS "is_admin") OR (( SELECT "private"."has_enabled_access"() AS "has_enabled_access") AND (( SELECT "auth"."uid"() AS "uid") = "user_id")))) WITH CHECK ((( SELECT "private"."is_admin"() AS "is_admin") OR (( SELECT "private"."has_enabled_access"() AS "has_enabled_access") AND (( SELECT "auth"."uid"() AS "uid") = "user_id"))));



CREATE POLICY "Deny audit log deletes" ON "public"."admin_audit_log" AS RESTRICTIVE FOR DELETE TO "authenticated", "anon" USING (false);



CREATE POLICY "Deny audit log updates" ON "public"."admin_audit_log" AS RESTRICTIVE FOR UPDATE TO "authenticated", "anon" USING (false) WITH CHECK (false);



CREATE POLICY "Enabled users can add calendar events" ON "public"."user_calendar_events" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "private"."has_enabled_access"() AS "has_enabled_access") AND (( SELECT "auth"."uid"() AS "uid") = "user_id")));



CREATE POLICY "Enabled users can add favorites" ON "public"."favorites" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "private"."has_enabled_access"() AS "has_enabled_access") AND (( SELECT "auth"."uid"() AS "uid") = "user_id")));



CREATE POLICY "Enabled users can add ratings" ON "public"."ratings" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "private"."has_enabled_access"() AS "has_enabled_access") AND (( SELECT "auth"."uid"() AS "uid") = "user_id")));



CREATE POLICY "Enabled users can delete own calendar events" ON "public"."user_calendar_events" FOR DELETE TO "authenticated" USING ((( SELECT "private"."has_enabled_access"() AS "has_enabled_access") AND (( SELECT "auth"."uid"() AS "uid") = "user_id")));



CREATE POLICY "Enabled users can delete own favorites" ON "public"."favorites" FOR DELETE TO "authenticated" USING ((( SELECT "private"."has_enabled_access"() AS "has_enabled_access") AND (( SELECT "auth"."uid"() AS "uid") = "user_id")));



CREATE POLICY "Enabled users can delete own ratings" ON "public"."ratings" FOR DELETE TO "authenticated" USING ((( SELECT "private"."has_enabled_access"() AS "has_enabled_access") AND (( SELECT "auth"."uid"() AS "uid") = "user_id")));



CREATE POLICY "Enabled users can insert signals" ON "public"."recommendation_signals" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "private"."has_enabled_access"() AS "has_enabled_access") AND (( SELECT "auth"."uid"() AS "uid") = "user_id")));



CREATE POLICY "Enabled users can read cities" ON "public"."cities" FOR SELECT TO "authenticated" USING ((( SELECT "private"."is_admin"() AS "is_admin") OR (( SELECT "private"."has_enabled_access"() AS "has_enabled_access") AND ("is_active" = true))));



CREATE POLICY "Enabled users can read event tags" ON "public"."event_tags" FOR SELECT TO "authenticated" USING ((( SELECT "private"."is_admin"() AS "is_admin") OR (( SELECT "private"."has_enabled_access"() AS "has_enabled_access") AND (EXISTS ( SELECT 1
   FROM "public"."events" "e"
  WHERE (("e"."id" = "event_tags"."event_id") AND ("e"."status" = 'published'::"text")))))));



CREATE POLICY "Enabled users can read ratings" ON "public"."ratings" FOR SELECT TO "authenticated" USING ((( SELECT "private"."is_admin"() AS "is_admin") OR (( SELECT "private"."has_enabled_access"() AS "has_enabled_access") AND (EXISTS ( SELECT 1
   FROM "public"."events" "e"
  WHERE (("e"."id" = "ratings"."event_id") AND ("e"."status" = 'published'::"text")))))));



CREATE POLICY "Enabled users can read tags" ON "public"."tags" FOR SELECT TO "authenticated" USING (( SELECT "private"."has_enabled_access"() AS "has_enabled_access"));



CREATE POLICY "Enabled users can update own ratings" ON "public"."ratings" FOR UPDATE TO "authenticated" USING ((( SELECT "private"."has_enabled_access"() AS "has_enabled_access") AND (( SELECT "auth"."uid"() AS "uid") = "user_id"))) WITH CHECK ((( SELECT "private"."has_enabled_access"() AS "has_enabled_access") AND (( SELECT "auth"."uid"() AS "uid") = "user_id")));



CREATE POLICY "Enabled users can view own calendar events" ON "public"."user_calendar_events" FOR SELECT TO "authenticated" USING ((( SELECT "private"."has_enabled_access"() AS "has_enabled_access") AND (( SELECT "auth"."uid"() AS "uid") = "user_id")));



CREATE POLICY "Enabled users can view own favorites" ON "public"."favorites" FOR SELECT TO "authenticated" USING ((( SELECT "private"."has_enabled_access"() AS "has_enabled_access") AND (( SELECT "auth"."uid"() AS "uid") = "user_id")));



CREATE POLICY "Enabled users can view own signals" ON "public"."recommendation_signals" FOR SELECT TO "authenticated" USING ((( SELECT "private"."has_enabled_access"() AS "has_enabled_access") AND (( SELECT "auth"."uid"() AS "uid") = "user_id")));



CREATE POLICY "No direct access to pending invite claims" ON "public"."pending_invite_claims" TO "authenticated" USING (false) WITH CHECK (false);



CREATE POLICY "Users can insert own profile" ON "public"."user_profiles" FOR INSERT TO "authenticated" WITH CHECK (((( SELECT "auth"."uid"() AS "uid") = "id") AND ("role" = 'user'::"text")));



CREATE POLICY "Users can update own profile (non-privileged columns)" ON "public"."user_profiles" FOR UPDATE TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "id")) WITH CHECK (((( SELECT "auth"."uid"() AS "uid") = "id") AND (NOT ("role" IS DISTINCT FROM ( SELECT "private"."current_profile_role"() AS "current_profile_role")))));



CREATE POLICY "Users can view own access or admins can view all access" ON "public"."user_access" FOR SELECT TO "authenticated" USING (((( SELECT "auth"."uid"() AS "uid") = "user_id") OR ( SELECT "private"."is_admin"() AS "is_admin")));



CREATE POLICY "Users can view own profile or admins can view all profiles" ON "public"."user_profiles" FOR SELECT TO "authenticated" USING (((( SELECT "auth"."uid"() AS "uid") = "id") OR ( SELECT "private"."is_admin"() AS "is_admin")));



ALTER TABLE "public"."admin_audit_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cities" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."comments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_ai_traces" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_sources" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_tag_queue" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_tags" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."favorites" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."invite_codes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."invite_redemption_attempts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."invite_request_attempts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."invite_requests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pending_invite_claims" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ratings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."recommendation_signals" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."source_extraction_traces" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."source_runs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."source_scrape_queue" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tags" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_access" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_calendar_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_profiles" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."comments";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."event_tag_queue";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."source_runs";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."source_scrape_queue";









GRANT USAGE ON SCHEMA "private" TO "anon";
GRANT USAGE ON SCHEMA "private" TO "authenticated";
GRANT USAGE ON SCHEMA "private" TO "service_role";



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";







































































































































































































































































































































REVOKE ALL ON FUNCTION "private"."admin_approve_invite_request"("p_request_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."admin_approve_invite_request"("p_request_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "private"."admin_approve_invite_request"("p_request_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "private"."admin_bulk_set_auto_approve"("enable" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."admin_bulk_set_auto_approve"("enable" boolean) TO "service_role";
GRANT ALL ON FUNCTION "private"."admin_bulk_set_auto_approve"("enable" boolean) TO "authenticated";



GRANT ALL ON TABLE "public"."events" TO "anon";
GRANT ALL ON TABLE "public"."events" TO "authenticated";
GRANT ALL ON TABLE "public"."events" TO "service_role";



REVOKE ALL ON FUNCTION "private"."admin_create_invite_code"("p_max_uses" integer, "p_expires_at" timestamp with time zone, "p_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."admin_create_invite_code"("p_max_uses" integer, "p_expires_at" timestamp with time zone, "p_notes" "text") TO "service_role";
GRANT ALL ON FUNCTION "private"."admin_create_invite_code"("p_max_uses" integer, "p_expires_at" timestamp with time zone, "p_notes" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "private"."admin_cron_run_history"("p_job_name" "text", "p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."admin_cron_run_history"("p_job_name" "text", "p_limit" integer) TO "service_role";
GRANT ALL ON FUNCTION "private"."admin_cron_run_history"("p_job_name" "text", "p_limit" integer) TO "authenticated";



REVOKE ALL ON FUNCTION "private"."admin_delete_rating"("p_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."admin_delete_rating"("p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "private"."admin_delete_rating"("p_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "private"."admin_list_cron_jobs"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."admin_list_cron_jobs"() TO "service_role";
GRANT ALL ON FUNCTION "private"."admin_list_cron_jobs"() TO "authenticated";



REVOKE ALL ON FUNCTION "private"."admin_reject_invite_request"("p_request_id" "uuid", "p_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."admin_reject_invite_request"("p_request_id" "uuid", "p_notes" "text") TO "service_role";
GRANT ALL ON FUNCTION "private"."admin_reject_invite_request"("p_request_id" "uuid", "p_notes" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "private"."admin_retry_source_scrape_queue"("p_queue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."admin_retry_source_scrape_queue"("p_queue_id" bigint) TO "service_role";
GRANT ALL ON FUNCTION "private"."admin_retry_source_scrape_queue"("p_queue_id" bigint) TO "authenticated";



REVOKE ALL ON FUNCTION "private"."admin_retry_tag_queue"("p_event_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."admin_retry_tag_queue"("p_event_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "private"."admin_retry_tag_queue"("p_event_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "private"."admin_revoke_invite_code"("p_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."admin_revoke_invite_code"("p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "private"."admin_revoke_invite_code"("p_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "private"."admin_run_due_scrapes"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."admin_run_due_scrapes"() TO "service_role";
GRANT ALL ON FUNCTION "private"."admin_run_due_scrapes"() TO "authenticated";



REVOKE ALL ON FUNCTION "private"."admin_set_cron_schedule"("p_job_name" "text", "p_schedule" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."admin_set_cron_schedule"("p_job_name" "text", "p_schedule" "text") TO "service_role";
GRANT ALL ON FUNCTION "private"."admin_set_cron_schedule"("p_job_name" "text", "p_schedule" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "private"."admin_toggle_cron_job"("p_job_name" "text", "p_active" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."admin_toggle_cron_job"("p_job_name" "text", "p_active" boolean) TO "service_role";
GRANT ALL ON FUNCTION "private"."admin_toggle_cron_job"("p_job_name" "text", "p_active" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "private"."bootstrap_admin"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."bootstrap_admin"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."canonicalize_invite_code"("p_code" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."claim_pending_invite_access"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."claim_pending_invite_access"() TO "service_role";
GRANT ALL ON FUNCTION "private"."claim_pending_invite_access"() TO "authenticated";



GRANT ALL ON TABLE "public"."source_scrape_queue" TO "anon";
GRANT ALL ON TABLE "public"."source_scrape_queue" TO "authenticated";
GRANT ALL ON TABLE "public"."source_scrape_queue" TO "service_role";



REVOKE ALL ON FUNCTION "private"."claim_source_scrape_queue_batch"("p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."claim_source_scrape_queue_batch"("p_limit" integer) TO "service_role";



GRANT ALL ON TABLE "public"."event_tag_queue" TO "anon";
GRANT ALL ON TABLE "public"."event_tag_queue" TO "authenticated";
GRANT ALL ON TABLE "public"."event_tag_queue" TO "service_role";



REVOKE ALL ON FUNCTION "private"."claim_tag_queue_batch"("p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."claim_tag_queue_batch"("p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "private"."cleanup_stale_source_runs"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."cleanup_stale_source_runs"() TO "service_role";



GRANT ALL ON FUNCTION "private"."delete_my_account"() TO "authenticated";
GRANT ALL ON FUNCTION "private"."delete_my_account"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."dispatch_email_notification"("p_payload" "jsonb") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."enforce_invited_oauth_signup"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."hash_invite_code"("p_code" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."invites_required"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."invites_required"() TO "service_role";
GRANT ALL ON FUNCTION "private"."invites_required"() TO "anon";
GRANT ALL ON FUNCTION "private"."invites_required"() TO "authenticated";



REVOKE ALL ON FUNCTION "private"."is_invite_rate_limited"("p_email_hash" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."is_invite_request_rate_limited"("p_email_hash" "text") FROM PUBLIC;



GRANT ALL ON FUNCTION "private"."list_railway_cron_jobs"() TO "authenticated";
GRANT ALL ON FUNCTION "private"."list_railway_cron_jobs"() TO "service_role";



GRANT ALL ON FUNCTION "private"."log_railway_cron_run"("p_label" "text", "p_status" "text", "p_http_status" integer, "p_duration_s" integer, "p_body" "text") TO "service_role";



REVOKE ALL ON FUNCTION "private"."mark_source_scrape_queue_skipped"("p_queue_id" bigint, "p_skip_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."mark_source_scrape_queue_skipped"("p_queue_id" bigint, "p_skip_reason" "text") TO "service_role";



REVOKE ALL ON FUNCTION "private"."mark_source_scrape_queue_started"("p_queue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."mark_source_scrape_queue_started"("p_queue_id" bigint) TO "service_role";



REVOKE ALL ON FUNCTION "private"."mark_tag_queue_row_started"("p_queue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."mark_tag_queue_row_started"("p_queue_id" bigint) TO "service_role";



REVOKE ALL ON FUNCTION "private"."plan_events_first_nonempty_window"("p_user_id" "uuid", "p_date" "date", "p_city_id" "uuid", "p_lat" double precision, "p_lng" double precision, "p_kid_age" integer, "p_weather_fit" "text", "p_limit" integer, "p_max_days" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."plan_events_first_nonempty_window"("p_user_id" "uuid", "p_date" "date", "p_city_id" "uuid", "p_lat" double precision, "p_lng" double precision, "p_kid_age" integer, "p_weather_fit" "text", "p_limit" integer, "p_max_days" integer) TO "service_role";
GRANT ALL ON FUNCTION "private"."plan_events_first_nonempty_window"("p_user_id" "uuid", "p_date" "date", "p_city_id" "uuid", "p_lat" double precision, "p_lng" double precision, "p_kid_age" integer, "p_weather_fit" "text", "p_limit" integer, "p_max_days" integer) TO "authenticated";



GRANT ALL ON FUNCTION "private"."railway_cron_run_history"("p_label" "text", "p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "private"."railway_cron_run_history"("p_label" "text", "p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "private"."reap_stuck_source_scrape_queue_rows"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."reap_stuck_source_scrape_queue_rows"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."reap_stuck_tag_queue_rows"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."reap_stuck_tag_queue_rows"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."redeem_invite"("p_code" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."redeem_invite"("p_code" "text") TO "service_role";



REVOKE ALL ON FUNCTION "private"."redeem_invite_for_email"("p_code" "text", "p_email" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."redeem_invite_for_email"("p_code" "text", "p_email" "text") TO "service_role";
GRANT ALL ON FUNCTION "private"."redeem_invite_for_email"("p_code" "text", "p_email" "text") TO "anon";
GRANT ALL ON FUNCTION "private"."redeem_invite_for_email"("p_code" "text", "p_email" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "private"."refresh_timezone_names"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."refresh_timezone_names"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."release_unstarted_source_scrape_queue_rows"("p_claimed_ids" bigint[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."release_unstarted_source_scrape_queue_rows"("p_claimed_ids" bigint[]) TO "service_role";



REVOKE ALL ON FUNCTION "private"."release_unstarted_tag_queue_rows"("p_claimed_ids" bigint[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."release_unstarted_tag_queue_rows"("p_claimed_ids" bigint[]) TO "service_role";



REVOKE ALL ON FUNCTION "private"."request_invite"("p_email" "text", "p_message" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."request_invite"("p_email" "text", "p_message" "text") TO "service_role";
GRANT ALL ON FUNCTION "private"."request_invite"("p_email" "text", "p_message" "text") TO "anon";
GRANT ALL ON FUNCTION "private"."request_invite"("p_email" "text", "p_message" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "private"."run_daily_maintenance"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."run_daily_maintenance"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."source_scrape_queue_schedule_retry"("p_queue_id" bigint, "p_attempt_count" integer, "p_error" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."source_scrape_queue_schedule_retry"("p_queue_id" bigint, "p_attempt_count" integer, "p_error" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_approve_invite_request"("p_request_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_approve_invite_request"("p_request_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_approve_invite_request"("p_request_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_bulk_set_auto_approve"("enable" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_bulk_set_auto_approve"("enable" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_bulk_set_auto_approve"("enable" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_create_event"("p_patch" "jsonb", "p_tag_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_create_event"("p_patch" "jsonb", "p_tag_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_create_event"("p_patch" "jsonb", "p_tag_ids" "uuid"[]) TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_create_invite_code"("p_max_uses" integer, "p_expires_at" timestamp with time zone, "p_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_create_invite_code"("p_max_uses" integer, "p_expires_at" timestamp with time zone, "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_create_invite_code"("p_max_uses" integer, "p_expires_at" timestamp with time zone, "p_notes" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_cron_run_history"("p_job_name" "text", "p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_cron_run_history"("p_job_name" "text", "p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_cron_run_history"("p_job_name" "text", "p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_delete_rating"("p_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_delete_rating"("p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_delete_rating"("p_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_list_cron_jobs"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_list_cron_jobs"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_list_cron_jobs"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_list_railway_cron_jobs"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_list_railway_cron_jobs"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_list_railway_cron_jobs"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_railway_cron_run_history"("p_label" "text", "p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_railway_cron_run_history"("p_label" "text", "p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_railway_cron_run_history"("p_label" "text", "p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_reject_invite_request"("p_request_id" "uuid", "p_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_reject_invite_request"("p_request_id" "uuid", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_reject_invite_request"("p_request_id" "uuid", "p_notes" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_retry_source_scrape_queue"("p_queue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_retry_source_scrape_queue"("p_queue_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_retry_source_scrape_queue"("p_queue_id" bigint) TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_retry_tag_queue"("p_event_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_retry_tag_queue"("p_event_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_retry_tag_queue"("p_event_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_revoke_invite_code"("p_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_revoke_invite_code"("p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_revoke_invite_code"("p_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_run_due_scrapes"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_run_due_scrapes"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_run_due_scrapes"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_set_cron_schedule"("p_job_name" "text", "p_schedule" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_set_cron_schedule"("p_job_name" "text", "p_schedule" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_set_cron_schedule"("p_job_name" "text", "p_schedule" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_toggle_cron_job"("p_job_name" "text", "p_active" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_toggle_cron_job"("p_job_name" "text", "p_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_toggle_cron_job"("p_job_name" "text", "p_active" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_unlock_event_fields"("p_event_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_unlock_event_fields"("p_event_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_unlock_event_fields"("p_event_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_update_event"("p_event_id" "uuid", "p_patch" "jsonb", "p_tag_ids" "uuid"[], "p_lock_edited_fields" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_update_event"("p_event_id" "uuid", "p_patch" "jsonb", "p_tag_ids" "uuid"[], "p_lock_edited_fields" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_update_event"("p_event_id" "uuid", "p_patch" "jsonb", "p_tag_ids" "uuid"[], "p_lock_edited_fields" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."claim_pending_invite_access"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."claim_pending_invite_access"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."claim_pending_invite_access"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."claim_source_scrape_queue_batch"("p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."claim_source_scrape_queue_batch"("p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."claim_tag_queue_batch"("p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."claim_tag_queue_batch"("p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."delete_my_account"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_my_account"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_my_account"() TO "service_role";



GRANT ALL ON FUNCTION "public"."events_enriched"("p_city_id" "uuid", "p_status" "text", "p_limit" integer, "p_offset" integer, "p_user_id" "uuid", "p_event_ids" "uuid"[], "p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."events_enriched"("p_city_id" "uuid", "p_status" "text", "p_limit" integer, "p_offset" integer, "p_user_id" "uuid", "p_event_ids" "uuid"[], "p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."events_enriched"("p_city_id" "uuid", "p_status" "text", "p_limit" integer, "p_offset" integer, "p_user_id" "uuid", "p_event_ids" "uuid"[], "p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."handle_new_user"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."invites_required"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."invites_required"() TO "anon";
GRANT ALL ON FUNCTION "public"."invites_required"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."invites_required"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."invoke_process_tag_queue"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."invoke_process_tag_queue"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."invoke_scrape_source"("source_uuid" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."invoke_scrape_source"("source_uuid" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_enabled_user"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_enabled_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_enabled_user"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."log_railway_cron_run"("p_label" "text", "p_status" "text", "p_http_status" integer, "p_duration_s" integer, "p_body" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."log_railway_cron_run"("p_label" "text", "p_status" "text", "p_http_status" integer, "p_duration_s" integer, "p_body" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."log_railway_cron_run"("p_label" "text", "p_status" "text", "p_http_status" integer, "p_duration_s" integer, "p_body" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."mark_source_scrape_queue_skipped"("p_queue_id" bigint, "p_skip_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."mark_source_scrape_queue_skipped"("p_queue_id" bigint, "p_skip_reason" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."mark_source_scrape_queue_started"("p_queue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."mark_source_scrape_queue_started"("p_queue_id" bigint) TO "service_role";



REVOKE ALL ON FUNCTION "public"."mark_tag_queue_row_started"("p_queue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."mark_tag_queue_row_started"("p_queue_id" bigint) TO "service_role";



REVOKE ALL ON FUNCTION "public"."plan_events_first_nonempty_window"("p_user_id" "uuid", "p_date" "date", "p_city_id" "uuid", "p_lat" double precision, "p_lng" double precision, "p_kid_age" integer, "p_weather_fit" "text", "p_limit" integer, "p_max_days" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."plan_events_first_nonempty_window"("p_user_id" "uuid", "p_date" "date", "p_city_id" "uuid", "p_lat" double precision, "p_lng" double precision, "p_kid_age" integer, "p_weather_fit" "text", "p_limit" integer, "p_max_days" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."plan_events_first_nonempty_window"("p_user_id" "uuid", "p_date" "date", "p_city_id" "uuid", "p_lat" double precision, "p_lng" double precision, "p_kid_age" integer, "p_weather_fit" "text", "p_limit" integer, "p_max_days" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."plan_events_for_user"("p_user_id" "uuid", "p_date" "date", "p_city_id" "uuid", "p_lat" double precision, "p_lng" double precision, "p_kid_age" integer, "p_weather_fit" "text", "p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."plan_events_for_user"("p_user_id" "uuid", "p_date" "date", "p_city_id" "uuid", "p_lat" double precision, "p_lng" double precision, "p_kid_age" integer, "p_weather_fit" "text", "p_limit" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."plan_events_for_user"("p_user_id" "uuid", "p_date" "date", "p_city_id" "uuid", "p_lat" double precision, "p_lng" double precision, "p_kid_age" integer, "p_weather_fit" "text", "p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."plan_events_for_user"("p_user_id" "uuid", "p_date" "date", "p_city_id" "uuid", "p_lat" double precision, "p_lng" double precision, "p_kid_age" integer, "p_weather_fit" "text", "p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."prevent_role_change"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."prevent_role_change"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."reap_stuck_source_scrape_queue_rows"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."reap_stuck_source_scrape_queue_rows"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."reap_stuck_tag_queue_rows"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."reap_stuck_tag_queue_rows"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."redeem_invite"("p_code" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."redeem_invite"("p_code" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."redeem_invite"("p_code" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."redeem_invite"("p_code" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."redeem_invite_for_email"("p_code" "text", "p_email" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."redeem_invite_for_email"("p_code" "text", "p_email" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."redeem_invite_for_email"("p_code" "text", "p_email" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."redeem_invite_for_email"("p_code" "text", "p_email" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."release_unstarted_source_scrape_queue_rows"("p_claimed_ids" bigint[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."release_unstarted_source_scrape_queue_rows"("p_claimed_ids" bigint[]) TO "service_role";



REVOKE ALL ON FUNCTION "public"."release_unstarted_tag_queue_rows"("p_claimed_ids" bigint[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."release_unstarted_tag_queue_rows"("p_claimed_ids" bigint[]) TO "service_role";



REVOKE ALL ON FUNCTION "public"."request_invite"("p_email" "text", "p_message" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."request_invite"("p_email" "text", "p_message" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."request_invite"("p_email" "text", "p_message" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."request_invite"("p_email" "text", "p_message" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."reset_comment_approval_for_non_admin"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."reset_comment_approval_for_non_admin"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."run_cleanup_stale_runs"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."run_cleanup_stale_runs"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."run_daily_maintenance"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."run_daily_maintenance"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."run_due_source_scrapes"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."run_due_source_scrapes"() TO "service_role";



GRANT ALL ON FUNCTION "public"."search_events"("p_city_id" "uuid", "p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone, "p_age_min" integer, "p_age_max" integer, "p_is_free" boolean, "p_is_featured" boolean, "p_tag_slugs" "text"[], "p_keyword" "text", "p_status" "text", "p_limit" integer, "p_offset" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."search_events"("p_city_id" "uuid", "p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone, "p_age_min" integer, "p_age_max" integer, "p_is_free" boolean, "p_is_featured" boolean, "p_tag_slugs" "text"[], "p_keyword" "text", "p_status" "text", "p_limit" integer, "p_offset" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."search_events"("p_city_id" "uuid", "p_date_from" timestamp with time zone, "p_date_to" timestamp with time zone, "p_age_min" integer, "p_age_max" integer, "p_is_free" boolean, "p_is_featured" boolean, "p_tag_slugs" "text"[], "p_keyword" "text", "p_status" "text", "p_limit" integer, "p_offset" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."source_scrape_queue_schedule_retry"("p_queue_id" bigint, "p_attempt_count" integer, "p_error" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."source_scrape_queue_schedule_retry"("p_queue_id" bigint, "p_attempt_count" integer, "p_error" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_event_search_vector"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_event_search_vector"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_event_search_vector"() TO "service_role";
























GRANT SELECT ON TABLE "private"."timezone_names_cache" TO "anon";
GRANT SELECT ON TABLE "private"."timezone_names_cache" TO "authenticated";
GRANT SELECT ON TABLE "private"."timezone_names_cache" TO "service_role";



GRANT ALL ON TABLE "public"."admin_audit_log" TO "anon";
GRANT ALL ON TABLE "public"."admin_audit_log" TO "authenticated";
GRANT ALL ON TABLE "public"."admin_audit_log" TO "service_role";



GRANT ALL ON TABLE "public"."cities" TO "anon";
GRANT ALL ON TABLE "public"."cities" TO "authenticated";
GRANT ALL ON TABLE "public"."cities" TO "service_role";



GRANT ALL ON TABLE "public"."comments" TO "anon";
GRANT ALL ON TABLE "public"."comments" TO "authenticated";
GRANT ALL ON TABLE "public"."comments" TO "service_role";



GRANT ALL ON TABLE "public"."event_ai_traces" TO "anon";
GRANT ALL ON TABLE "public"."event_ai_traces" TO "authenticated";
GRANT ALL ON TABLE "public"."event_ai_traces" TO "service_role";



GRANT ALL ON TABLE "public"."ratings" TO "anon";
GRANT ALL ON TABLE "public"."ratings" TO "authenticated";
GRANT ALL ON TABLE "public"."ratings" TO "service_role";



GRANT ALL ON TABLE "public"."event_rating_stats" TO "anon";
GRANT ALL ON TABLE "public"."event_rating_stats" TO "authenticated";
GRANT ALL ON TABLE "public"."event_rating_stats" TO "service_role";



GRANT ALL ON TABLE "public"."event_sources" TO "anon";
GRANT ALL ON TABLE "public"."event_sources" TO "authenticated";
GRANT ALL ON TABLE "public"."event_sources" TO "service_role";



GRANT ALL ON SEQUENCE "public"."event_tag_queue_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."event_tag_queue_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."event_tag_queue_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."event_tag_queue_summary" TO "anon";
GRANT ALL ON TABLE "public"."event_tag_queue_summary" TO "authenticated";
GRANT ALL ON TABLE "public"."event_tag_queue_summary" TO "service_role";



GRANT ALL ON TABLE "public"."event_tags" TO "anon";
GRANT ALL ON TABLE "public"."event_tags" TO "authenticated";
GRANT ALL ON TABLE "public"."event_tags" TO "service_role";



GRANT ALL ON TABLE "public"."favorites" TO "anon";
GRANT ALL ON TABLE "public"."favorites" TO "authenticated";
GRANT ALL ON TABLE "public"."favorites" TO "service_role";



GRANT ALL ON TABLE "public"."invite_codes" TO "anon";
GRANT ALL ON TABLE "public"."invite_codes" TO "authenticated";
GRANT ALL ON TABLE "public"."invite_codes" TO "service_role";



GRANT ALL ON TABLE "public"."invite_redemption_attempts" TO "anon";
GRANT ALL ON TABLE "public"."invite_redemption_attempts" TO "authenticated";
GRANT ALL ON TABLE "public"."invite_redemption_attempts" TO "service_role";



GRANT ALL ON SEQUENCE "public"."invite_redemption_attempts_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."invite_redemption_attempts_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."invite_redemption_attempts_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."invite_request_attempts" TO "anon";
GRANT ALL ON TABLE "public"."invite_request_attempts" TO "authenticated";
GRANT ALL ON TABLE "public"."invite_request_attempts" TO "service_role";



GRANT ALL ON SEQUENCE "public"."invite_request_attempts_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."invite_request_attempts_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."invite_request_attempts_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."invite_requests" TO "anon";
GRANT ALL ON TABLE "public"."invite_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."invite_requests" TO "service_role";



GRANT ALL ON TABLE "public"."pending_invite_claims" TO "anon";
GRANT ALL ON TABLE "public"."pending_invite_claims" TO "authenticated";
GRANT ALL ON TABLE "public"."pending_invite_claims" TO "service_role";



GRANT ALL ON TABLE "public"."public_events" TO "anon";
GRANT ALL ON TABLE "public"."public_events" TO "authenticated";
GRANT ALL ON TABLE "public"."public_events" TO "service_role";



GRANT ALL ON TABLE "public"."recommendation_signals" TO "anon";
GRANT ALL ON TABLE "public"."recommendation_signals" TO "authenticated";
GRANT ALL ON TABLE "public"."recommendation_signals" TO "service_role";



GRANT ALL ON TABLE "public"."source_extraction_traces" TO "anon";
GRANT ALL ON TABLE "public"."source_extraction_traces" TO "authenticated";
GRANT ALL ON TABLE "public"."source_extraction_traces" TO "service_role";



GRANT ALL ON SEQUENCE "public"."source_extraction_traces_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."source_extraction_traces_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."source_extraction_traces_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."source_runs" TO "anon";
GRANT ALL ON TABLE "public"."source_runs" TO "authenticated";
GRANT ALL ON TABLE "public"."source_runs" TO "service_role";



GRANT ALL ON SEQUENCE "public"."source_scrape_queue_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."source_scrape_queue_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."source_scrape_queue_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."source_scrape_queue_summary" TO "anon";
GRANT ALL ON TABLE "public"."source_scrape_queue_summary" TO "authenticated";
GRANT ALL ON TABLE "public"."source_scrape_queue_summary" TO "service_role";



GRANT ALL ON TABLE "public"."tags" TO "anon";
GRANT ALL ON TABLE "public"."tags" TO "authenticated";
GRANT ALL ON TABLE "public"."tags" TO "service_role";



GRANT ALL ON TABLE "public"."timezone_names" TO "anon";
GRANT ALL ON TABLE "public"."timezone_names" TO "authenticated";
GRANT ALL ON TABLE "public"."timezone_names" TO "service_role";



GRANT ALL ON TABLE "public"."user_access" TO "anon";
GRANT ALL ON TABLE "public"."user_access" TO "authenticated";
GRANT ALL ON TABLE "public"."user_access" TO "service_role";



GRANT ALL ON TABLE "public"."user_calendar_events" TO "anon";
GRANT ALL ON TABLE "public"."user_calendar_events" TO "authenticated";
GRANT ALL ON TABLE "public"."user_calendar_events" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."user_profiles" TO "anon";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."user_profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."user_profiles" TO "service_role";


REVOKE UPDATE ON TABLE "public"."user_profiles" FROM "anon", "authenticated";



GRANT UPDATE("email") ON TABLE "public"."user_profiles" TO "authenticated";



GRANT UPDATE("display_name") ON TABLE "public"."user_profiles" TO "authenticated";



GRANT UPDATE("avatar_url") ON TABLE "public"."user_profiles" TO "authenticated";



GRANT UPDATE("city_preference_id") ON TABLE "public"."user_profiles" TO "authenticated";



GRANT UPDATE("child_name") ON TABLE "public"."user_profiles" TO "authenticated";



GRANT UPDATE("child_age") ON TABLE "public"."user_profiles" TO "authenticated";



GRANT UPDATE("updated_at") ON TABLE "public"."user_profiles" TO "authenticated";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";
































--
-- Dumped schema changes for auth and storage
--

CREATE OR REPLACE TRIGGER "enforce_invited_oauth_signup" BEFORE INSERT ON "auth"."users" FOR EACH ROW EXECUTE FUNCTION "private"."enforce_invited_oauth_signup"();



CREATE OR REPLACE TRIGGER "on_auth_user_created" AFTER INSERT ON "auth"."users" FOR EACH ROW EXECUTE FUNCTION "public"."handle_new_user"();

