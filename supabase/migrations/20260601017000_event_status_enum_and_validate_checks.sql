-- T3.2 (M5/M4): convert public.events.status from text to a native enum
-- (public.event_status) and VALIDATE the six NOT VALID data-integrity
-- constraints added in 20260601001000_reference_security_and_cron.sql.
--
-- Risk notes:
--   * Multi-step column swap. Dependent objects whose stored predicate is
--     `status = 'published'::text` (5 partial indexes, the public_events view,
--     5 RLS policies) are dropped before the type change and recreated after
--     with a bare 'published' literal that coerces to the enum.
--   * Functions that compared/assigned events.status against a text parameter
--     are recreated: SELECT filters cast the column to text (`e.status::text`)
--     so callers may keep passing arbitrary text without an invalid-enum error;
--     writers cast the text value to the enum.
--   * Plain btree indexes on status (events_status_idx, events_status_start_datetime_idx,
--     events_admin_status_created_idx, events_admin_status_city_created_idx) are
--     rebuilt automatically by ALTER COLUMN ... TYPE and need no handling.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Conservative pre-validation cleanup. Touches only rows that violate the
--    NOT VALID constraints so VALIDATE below cannot fail on legacy data.
-- ---------------------------------------------------------------------------
UPDATE public.events SET age_min = NULL WHERE age_min IS NOT NULL AND age_min < 0;
UPDATE public.events SET age_max = NULL WHERE age_max IS NOT NULL AND age_max < 0;
UPDATE public.events SET age_min = NULL
  WHERE age_min IS NOT NULL AND age_max IS NOT NULL AND age_min > age_max;
UPDATE public.events SET latitude = NULL
  WHERE latitude IS NOT NULL AND latitude NOT BETWEEN -90 AND 90;
UPDATE public.events SET longitude = NULL
  WHERE longitude IS NOT NULL AND longitude NOT BETWEEN -180 AND 180;
UPDATE public.events SET price = NULL WHERE price IS NOT NULL AND price < 0;
UPDATE public.user_profiles SET child_age = NULL
  WHERE child_age IS NOT NULL AND child_age NOT BETWEEN 0 AND 18;
UPDATE public.invite_codes SET used_count = max_uses WHERE used_count > max_uses;
UPDATE public.event_sources
  SET scrape_interval_hours = LEAST(GREATEST(scrape_interval_hours, 1), 720)
  WHERE scrape_interval_hours NOT BETWEEN 1 AND 720;

-- ---------------------------------------------------------------------------
-- 2. Create the native enum (members match the dropped CHECK).
-- ---------------------------------------------------------------------------
CREATE TYPE public.event_status AS ENUM ('draft', 'published', 'rejected', 'archived');

-- ---------------------------------------------------------------------------
-- 3. Drop dependents whose stored predicate carries an explicit ::text cast
--    (these would block / break the column type change).
-- ---------------------------------------------------------------------------
DROP INDEX IF EXISTS public.events_local_date_published_idx;
DROP INDEX IF EXISTS public.events_published_city_start_datetime_idx;
DROP INDEX IF EXISTS public.events_published_feed_idx;
DROP INDEX IF EXISTS public.events_published_local_date_city_idx;
DROP INDEX IF EXISTS public.events_published_start_id_idx;

DROP POLICY IF EXISTS "Enabled users can read ratings" ON public.ratings;
DROP POLICY IF EXISTS "Enabled users can read event tags" ON public.event_tags;
DROP POLICY IF EXISTS "Authenticated users can read approved comments or admins can re" ON public.comments;
DROP POLICY IF EXISTS "Anon can read published events" ON public.events;
DROP POLICY IF EXISTS "Authenticated reads published or admin reads all" ON public.events;

DROP VIEW IF EXISTS public.public_events;

-- ---------------------------------------------------------------------------
-- 4. Swap the column type and drop the now-redundant CHECK constraint.
-- ---------------------------------------------------------------------------
ALTER TABLE public.events ALTER COLUMN status DROP DEFAULT;
ALTER TABLE public.events
  ALTER COLUMN status TYPE public.event_status USING status::public.event_status;
ALTER TABLE public.events ALTER COLUMN status SET DEFAULT 'draft'::public.event_status;
ALTER TABLE public.events DROP CONSTRAINT IF EXISTS events_status_check;

-- ---------------------------------------------------------------------------
-- 5. Recreate the dropped dependents with bare 'published' literals
--    (coerced to public.event_status).
-- ---------------------------------------------------------------------------
CREATE INDEX events_local_date_published_idx ON public.events
  USING btree ((((start_datetime AT TIME ZONE timezone))::date))
  WHERE (status = 'published');
CREATE INDEX events_published_city_start_datetime_idx ON public.events
  USING btree (city_id, start_datetime)
  WHERE (status = 'published');
CREATE INDEX events_published_feed_idx ON public.events
  USING btree (city_id, start_datetime, id)
  WHERE (status = 'published');
CREATE INDEX events_published_local_date_city_idx ON public.events
  USING btree ((((start_datetime AT TIME ZONE timezone))::date), city_id, id)
  WHERE (status = 'published');
CREATE INDEX events_published_start_id_idx ON public.events
  USING btree (start_datetime, id)
  WHERE (status = 'published');

CREATE OR REPLACE VIEW public.public_events WITH (security_invoker='true') AS
 SELECT id, title, description, start_datetime, end_datetime, timezone,
        venue_name, address, city_id, latitude, longitude, age_min, age_max,
        price, is_free, source_url, source_name, images, recurrence_info, is_featured
   FROM public.events e
  WHERE status = 'published';
ALTER VIEW public.public_events OWNER TO postgres;
GRANT ALL ON TABLE public.public_events TO anon;
GRANT ALL ON TABLE public.public_events TO authenticated;
GRANT ALL ON TABLE public.public_events TO service_role;

CREATE POLICY "Anon can read published events" ON public.events
  FOR SELECT TO anon USING (status = 'published');

CREATE POLICY "Authenticated reads published or admin reads all" ON public.events
  FOR SELECT TO authenticated
  USING ((( SELECT private.is_admin() AS is_admin) OR (status = 'published')));

CREATE POLICY "Authenticated users can read approved comments or admins can re" ON public.comments
  FOR SELECT TO authenticated
  USING ((( SELECT private.is_admin() AS is_admin)
    OR (( SELECT private.has_enabled_access() AS has_enabled_access)
        AND (is_approved = true)
        AND (EXISTS ( SELECT 1 FROM public.events e
                       WHERE ((e.id = comments.event_id) AND (e.status = 'published')))))));

CREATE POLICY "Enabled users can read event tags" ON public.event_tags
  FOR SELECT TO authenticated
  USING ((( SELECT private.is_admin() AS is_admin)
    OR (( SELECT private.has_enabled_access() AS has_enabled_access)
        AND (EXISTS ( SELECT 1 FROM public.events e
                       WHERE ((e.id = event_tags.event_id) AND (e.status = 'published')))))));

CREATE POLICY "Enabled users can read ratings" ON public.ratings
  FOR SELECT TO authenticated
  USING ((( SELECT private.is_admin() AS is_admin)
    OR (( SELECT private.has_enabled_access() AS has_enabled_access)
        AND (EXISTS ( SELECT 1 FROM public.events e
                       WHERE ((e.id = ratings.event_id) AND (e.status = 'published')))))));

-- ---------------------------------------------------------------------------
-- 6. Recreate functions that compared/assigned events.status against text.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.admin_set_event_status(p_event_id uuid, p_status text)
 RETURNS events
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  before_row public.events%ROWTYPE;
  updated_row public.events%ROWTYPE;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_EVENT_ADMIN_REQUIRED';
  END IF;

  IF p_status <> ALL (ARRAY['draft', 'published', 'rejected', 'archived']) THEN
    RAISE EXCEPTION 'ADMIN_EVENT_INVALID_STATUS';
  END IF;

  SELECT *
    INTO before_row
    FROM public.events
   WHERE id = p_event_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ADMIN_EVENT_NOT_FOUND';
  END IF;

  UPDATE public.events
     SET status = p_status::public.event_status,
         admin_last_edited_at = now(),
         admin_last_edited_by = auth.uid(),
         updated_at = now()
   WHERE id = p_event_id
   RETURNING * INTO updated_row;

  INSERT INTO public.admin_audit_log (admin_user_id, action, target_type, target_id, metadata)
  VALUES (
    auth.uid(),
    'event.status.update',
    'event',
    p_event_id,
    jsonb_build_object('previous_status', before_row.status, 'status', p_status)
  );

  RETURN updated_row;
END;
$function$;


CREATE OR REPLACE FUNCTION private.admin_batch_set_event_status(p_event_ids uuid[], p_status text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  affected integer;
  previous_rows jsonb;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_EVENT_ADMIN_REQUIRED';
  END IF;

  IF p_status <> ALL (ARRAY['draft', 'published', 'rejected', 'archived']) THEN
    RAISE EXCEPTION 'ADMIN_EVENT_INVALID_STATUS';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(e) ORDER BY e.id), '[]'::jsonb)
    INTO previous_rows
    FROM public.events e
   WHERE e.id = ANY (COALESCE(p_event_ids, '{}'::uuid[]));

  UPDATE public.events
     SET status = p_status::public.event_status,
         admin_last_edited_at = now(),
         admin_last_edited_by = auth.uid(),
         updated_at = now()
   WHERE id = ANY (COALESCE(p_event_ids, '{}'::uuid[]));

  GET DIAGNOSTICS affected = ROW_COUNT;

  INSERT INTO public.admin_audit_log (admin_user_id, action, target_type, metadata)
  VALUES (
    auth.uid(),
    'event.status.batch_update',
    'events',
    jsonb_build_object(
      'event_ids', to_jsonb(COALESCE(p_event_ids, '{}'::uuid[])),
      'status', p_status,
      'affected_count', affected,
      'previous', previous_rows
    )
  );

  RETURN affected;
END;
$function$;


CREATE OR REPLACE FUNCTION private.admin_update_event_status(p_event_id uuid, p_status text, p_reason text DEFAULT NULL::text)
 RETURNS events
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  before_row public.events%ROWTYPE;
  updated_row public.events%ROWTYPE;
  v_reason text;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_status <> ALL (ARRAY['draft', 'published', 'rejected', 'archived']) THEN
    RAISE EXCEPTION 'invalid event status: %', p_status USING ERRCODE = '22023';
  END IF;

  v_reason := NULLIF(btrim(COALESCE(p_reason, '')), '');

  SELECT * INTO before_row
  FROM public.events
  WHERE id = p_event_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'event not found: %', p_event_id USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.events
  SET status = p_status::public.event_status,
      admin_last_edited_at = now(),
      admin_last_edited_by = auth.uid(),
      updated_at = now()
  WHERE id = p_event_id
  RETURNING * INTO updated_row;

  INSERT INTO public.admin_audit_log (admin_user_id, action, target_type, target_id, metadata)
  VALUES (
    auth.uid(),
    'event.status.update',
    'event',
    p_event_id,
    jsonb_build_object(
      'previous_status', before_row.status,
      'status', updated_row.status,
      'reason', v_reason,
      'previous_llm_review_status', before_row.llm_review_status,
      'llm_review_status', updated_row.llm_review_status,
      'previous_llm_review_decision', before_row.llm_review_decision,
      'llm_review_decision', updated_row.llm_review_decision
    )
  );

  RETURN updated_row;
END;
$function$;


CREATE OR REPLACE FUNCTION private.apply_event_llm_review_decision(p_queue_id bigint, p_event_id uuid, p_source_id uuid, p_source_run_id uuid, p_provider text, p_model text, p_prompt_version text, p_review_status llm_event_review_status, p_model_decision llm_event_review_decision, p_applied_decision llm_event_review_decision, p_confidence numeric, p_reason text, p_flags text[], p_suggested_category text, p_normalized_title text, p_raw_response jsonb, p_error_code text, p_error_message text, p_input_snapshot jsonb, p_processing_ms integer)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_event_id uuid;
  v_next_event_status text;
  v_now timestamptz := now();
BEGIN
  v_next_event_status := CASE
    WHEN p_applied_decision = 'approve'::public.llm_event_review_decision THEN 'published'
    WHEN p_applied_decision = 'reject'::public.llm_event_review_decision THEN 'rejected'
    ELSE 'draft'
  END;

  UPDATE public.events
  SET status = v_next_event_status::public.event_status,
      llm_review_status = p_review_status,
      llm_review_decision = p_applied_decision,
      llm_review_confidence = p_confidence,
      llm_review_reason = p_reason,
      llm_review_flags = COALESCE(p_flags, '{}'::text[]),
      llm_review_provider = p_provider,
      llm_review_model = p_model,
      llm_review_prompt_version = p_prompt_version,
      llm_reviewed_at = v_now,
      llm_review_error = p_error_message,
      updated_at = v_now
  WHERE id = p_event_id
    AND status = 'draft'
  RETURNING id INTO v_event_id;

  IF v_event_id IS NULL THEN
    RETURN false;
  END IF;

  INSERT INTO public.event_llm_review_traces (
    event_id,
    queue_id,
    source_id,
    source_run_id,
    provider,
    model,
    prompt_version,
    status,
    model_decision,
    applied_decision,
    confidence,
    reason,
    flags,
    suggested_category,
    normalized_title,
    raw_response,
    error_code,
    error_message,
    input_snapshot,
    processing_ms
  )
  VALUES (
    p_event_id,
    p_queue_id,
    p_source_id,
    p_source_run_id,
    p_provider,
    p_model,
    p_prompt_version,
    p_review_status,
    p_model_decision,
    p_applied_decision,
    p_confidence,
    p_reason,
    COALESCE(p_flags, '{}'::text[]),
    p_suggested_category,
    p_normalized_title,
    p_raw_response,
    p_error_code,
    p_error_message,
    p_input_snapshot,
    p_processing_ms
  );

  IF p_applied_decision <> 'reject'::public.llm_event_review_decision THEN
    INSERT INTO public.event_tag_queue (event_id, source_run_id, trigger_type)
    VALUES (p_event_id, p_source_run_id, 'import')
    ON CONFLICT (event_id) WHERE status IN ('pending', 'processing')
      DO NOTHING;
  END IF;

  UPDATE public.event_llm_review_queue
  SET status = 'succeeded',
      finished_at = v_now,
      last_error = NULL,
      updated_at = v_now
  WHERE id = p_queue_id;

  RETURN true;
END;
$function$;


CREATE OR REPLACE FUNCTION private.bulk_import_scrape_events(p_run_id uuid, p_source_id uuid, p_events jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_auto_approve   boolean;
  v_processing_mode public.event_processing_mode;
  v_imported       int := 0;
  v_updated        int := 0;
  v_skipped        int := 0;
  v_enqueued       int := 0;
BEGIN
  SELECT
    auto_approve,
    processing_mode
  INTO
    v_auto_approve,
    v_processing_mode
  FROM public.event_sources
  WHERE id = p_source_id;

  IF v_auto_approve IS NULL AND v_processing_mode IS NULL THEN
    RAISE EXCEPTION 'source not found: %', p_source_id USING ERRCODE = 'P0002';
  END IF;

  IF v_processing_mode IS NULL THEN
    v_processing_mode := CASE
      WHEN COALESCE(v_auto_approve, false) THEN 'auto_approve'::public.event_processing_mode
      ELSE 'manual_review'::public.event_processing_mode
    END;
  END IF;

  DROP TABLE IF EXISTS _bulk_input;
  CREATE TEMP TABLE _bulk_input ON COMMIT DROP AS
  WITH inputs AS (
    SELECT
      (idx - 1)::int AS ord,
      (elem->>'title')::text                    AS title,
      (elem->>'description')::text              AS description,
      (elem->>'start_datetime')::timestamptz    AS start_datetime,
      NULLIF(elem->>'end_datetime', '')::timestamptz AS end_datetime,
      (elem->>'timezone')::text                 AS timezone,
      (elem->>'venue_name')::text               AS venue_name,
      (elem->>'address')::text                  AS address,
      NULLIF(elem->>'city_id', '')::uuid        AS city_id,
      NULLIF(elem->>'source_url', '')::text     AS source_url,
      (elem->>'source_name')::text              AS source_name,
      COALESCE(elem->'images', '[]'::jsonb)     AS images,
      NULLIF(elem->>'price', '')::numeric       AS price,
      COALESCE((elem->>'is_free')::boolean, false) AS is_free,
      NULLIF(elem->>'is_outdoor', '')::boolean  AS is_outdoor,
      NULLIF(elem->>'latitude', '')::numeric    AS latitude,
      NULLIF(elem->>'longitude', '')::numeric   AS longitude
    FROM jsonb_array_elements(p_events) WITH ORDINALITY AS j(elem, idx)
  ),
  classified AS (
    SELECT
      i.*,
      su.id AS source_url_match
    FROM inputs i
    LEFT JOIN LATERAL (
      SELECT e.id FROM public.events e
      WHERE e.source_id = p_source_id
        AND e.source_url IS NOT NULL
        AND e.source_url = i.source_url
      LIMIT 1
    ) su ON i.source_url IS NOT NULL
  )
  SELECT
    c.*,
    CASE
      WHEN c.source_url_match IS NOT NULL THEN 'update'
      ELSE 'insert'
    END AS decision,
    c.source_url_match AS target_event_id
  FROM classified c;

  DROP TABLE IF EXISTS _bulk_inserted;
  CREATE TEMP TABLE _bulk_inserted ON COMMIT DROP AS
  WITH src AS (
    SELECT * FROM _bulk_input WHERE decision = 'insert'
  ),
  ins AS (
    INSERT INTO public.events (
      title, description, start_datetime, end_datetime, timezone,
      venue_name, address, city_id, latitude, longitude,
      price, is_free, is_outdoor,
      source_url, source_name, source_id,
      images, status,
      llm_review_status,
      llm_review_decision,
      llm_review_confidence,
      llm_review_reason,
      llm_review_flags,
      llm_review_provider,
      llm_review_model,
      llm_review_prompt_version,
      llm_reviewed_at,
      llm_review_error
    )
    SELECT
      s.title, s.description, s.start_datetime, s.end_datetime, s.timezone,
      s.venue_name, s.address, s.city_id, s.latitude, s.longitude,
      s.price, s.is_free, s.is_outdoor,
      s.source_url, s.source_name, p_source_id,
      s.images,
      CASE
        WHEN v_processing_mode = 'auto_approve'::public.event_processing_mode THEN 'published'::public.event_status
        ELSE 'draft'::public.event_status
      END,
      CASE
        WHEN v_processing_mode = 'llm_review'::public.event_processing_mode
          THEN 'pending'::public.llm_event_review_status
        ELSE 'not_required'::public.llm_event_review_status
      END,
      NULL,
      NULL,
      NULL,
      '{}'::text[],
      NULL,
      NULL,
      NULL,
      NULL,
      NULL
    FROM src s
    ON CONFLICT (source_id, source_url)
      WHERE source_url IS NOT NULL
      DO NOTHING
    RETURNING id, source_url
  )
  SELECT id, source_url FROM ins;

  GET DIAGNOSTICS v_imported = ROW_COUNT;

  DROP TABLE IF EXISTS _bulk_update_targets;
  CREATE TEMP TABLE _bulk_update_targets ON COMMIT DROP AS
  SELECT b.*, e.id AS event_id, e.admin_locked_fields
  FROM _bulk_input b
  JOIN public.events e
    ON e.source_id = p_source_id
   AND e.source_url IS NOT NULL
   AND e.source_url = b.source_url
  WHERE b.decision = 'update'
     OR (b.decision = 'insert' AND b.source_url IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM _bulk_inserted i WHERE i.source_url = b.source_url));

  WITH updated AS (
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
      llm_review_status = CASE
        WHEN v_processing_mode = 'llm_review'::public.event_processing_mode
          THEN 'pending'::public.llm_event_review_status
        ELSE 'not_required'::public.llm_event_review_status
      END,
      llm_review_decision = NULL,
      llm_review_confidence = NULL,
      llm_review_reason = NULL,
      llm_review_flags = '{}'::text[],
      llm_review_provider = NULL,
      llm_review_model = NULL,
      llm_review_prompt_version = NULL,
      llm_reviewed_at = NULL,
      llm_review_error = NULL,
      updated_at     = now()
    FROM _bulk_update_targets t
    WHERE e.id = t.event_id
    RETURNING e.id
  )
  SELECT COUNT(*) INTO v_updated FROM updated;

  WITH all_imported AS (
    SELECT id FROM _bulk_inserted
    UNION ALL
    SELECT event_id AS id FROM _bulk_update_targets
  ),
  enq AS (
    INSERT INTO public.event_llm_review_queue (event_id, source_id, source_run_id, trigger_type)
    SELECT id, p_source_id, p_run_id, 'import'
    FROM all_imported
    WHERE v_processing_mode = 'llm_review'::public.event_processing_mode
    ON CONFLICT (event_id) WHERE status IN ('pending', 'processing', 'retrying')
      DO NOTHING
    RETURNING id
  ),
  tag_enq AS (
    INSERT INTO public.event_tag_queue (event_id, source_run_id, trigger_type)
    SELECT id, p_run_id, 'import'
    FROM all_imported
    WHERE v_processing_mode <> 'llm_review'::public.event_processing_mode
    ON CONFLICT (event_id) WHERE status IN ('pending', 'processing')
      DO NOTHING
    RETURNING id
  )
  SELECT
    COALESCE((SELECT COUNT(*) FROM enq), 0) + COALESCE((SELECT COUNT(*) FROM tag_enq), 0)
  INTO v_enqueued;

  RETURN jsonb_build_object(
    'imported', v_imported,
    'updated',  v_updated,
    'skipped',  v_skipped,
    'enqueued', v_enqueued
  );
END;
$function$;


CREATE OR REPLACE FUNCTION public.events_enriched(p_city_id uuid DEFAULT NULL::uuid, p_status text DEFAULT 'published'::text, p_user_id uuid DEFAULT NULL::uuid, p_event_ids uuid[] DEFAULT NULL::uuid[], p_date_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_date_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_after_start_datetime timestamp with time zone DEFAULT NULL::timestamp with time zone, p_after_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 24)
 RETURNS TABLE(id uuid, title text, description text, start_datetime timestamp with time zone, end_datetime timestamp with time zone, timezone text, venue_name text, address text, city_id uuid, latitude numeric, longitude numeric, age_min integer, age_max integer, price numeric, is_free boolean, source_url text, source_name text, source_id uuid, images jsonb, status text, ai_confidence numeric, ai_tag_provider text, recurrence_info jsonb, is_featured boolean, is_outdoor boolean, parent_tips jsonb, parent_tips_generated_at timestamp with time zone, view_count integer, search_vector tsvector, created_at timestamp with time zone, updated_at timestamp with time zone, avg_rating numeric, rating_count integer, tags jsonb, image_attributions jsonb, is_favorited boolean, is_in_calendar boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT
    e.id, e.title, e.description, e.start_datetime, e.end_datetime, e.timezone,
    e.venue_name, e.address, e.city_id, e.latitude, e.longitude,
    e.age_min, e.age_max, e.price, e.is_free,
    e.source_url, e.source_name, e.source_id, e.images, e.status::text,
    e.ai_confidence, e.ai_tag_provider, e.recurrence_info, e.is_featured,
    e.is_outdoor, e.parent_tips, e.parent_tips_generated_at,
    e.view_count,
    e.search_vector, e.created_at, e.updated_at,
    COALESCE(rs.avg_score, 0)::numeric    AS avg_rating,
    COALESCE(rs.rating_count, 0)::int     AS rating_count,
    COALESCE(ts.tags, '[]'::jsonb)        AS tags,
    COALESCE(ias.image_attributions, '[]'::jsonb) AS image_attributions,
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
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(
             jsonb_build_object(
               'provider', a.provider,
               'image_url', a.image_url,
               'matched_tag', a.matched_tag,
               'photo_id', a.unsplash_photo_id,
               'photographer_name', a.unsplash_photographer_name,
               'photographer_username', a.unsplash_photographer_username,
               'photographer_profile_url', a.unsplash_photographer_profile_url,
               'photo_url', a.unsplash_photo_url
             )
             ORDER BY a.created_at ASC
           ) AS image_attributions
    FROM public.event_image_attributions a
    WHERE a.event_id = e.id
  ) ias ON TRUE
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
        AND e.status::text = p_status
        AND (p_city_id IS NULL OR e.city_id = p_city_id)
    )
    AND (
      p_after_start_datetime IS NULL
      OR (e.start_datetime, e.id) > (p_after_start_datetime, p_after_id)
    )
  ORDER BY e.start_datetime ASC, e.id ASC
  LIMIT CASE WHEN p_event_ids IS NULL THEN LEAST(GREATEST(p_limit, 1), 500) ELSE NULL END;
$function$;


CREATE OR REPLACE FUNCTION public.search_events(p_city_id uuid DEFAULT NULL::uuid, p_date_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_date_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_age_min integer DEFAULT NULL::integer, p_age_max integer DEFAULT NULL::integer, p_is_free boolean DEFAULT NULL::boolean, p_is_featured boolean DEFAULT NULL::boolean, p_tag_slugs text[] DEFAULT NULL::text[], p_keyword text DEFAULT NULL::text, p_status text DEFAULT 'published'::text, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0, p_after_start_datetime timestamp with time zone DEFAULT NULL::timestamp with time zone, p_after_id uuid DEFAULT NULL::uuid)
 RETURNS SETOF events
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
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
  WHERE e.status::text = p_status
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
    AND (
      p_after_start_datetime IS NULL
      OR (e.start_datetime, e.id) > (p_after_start_datetime, p_after_id)
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
$function$;


CREATE OR REPLACE FUNCTION private.admin_events_enriched(p_status text DEFAULT NULL::text, p_city_id uuid DEFAULT NULL::uuid, p_city_is_null boolean DEFAULT NULL::boolean, p_keyword text DEFAULT NULL::text, p_after_created_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_after_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50, p_llm_review_status llm_event_review_status DEFAULT NULL::llm_event_review_status, p_llm_review_decision llm_event_review_decision DEFAULT NULL::llm_event_review_decision, p_llm_reviewed boolean DEFAULT NULL::boolean)
 RETURNS TABLE(id uuid, title text, description text, start_datetime timestamp with time zone, end_datetime timestamp with time zone, timezone text, venue_name text, address text, city_id uuid, latitude numeric, longitude numeric, age_min integer, age_max integer, price numeric, is_free boolean, source_url text, source_name text, source_id uuid, images jsonb, status text, ai_confidence numeric, ai_tag_provider text, recurrence_info jsonb, is_featured boolean, view_count integer, search_vector tsvector, admin_locked_fields text[], admin_last_edited_at timestamp with time zone, admin_last_edited_by uuid, created_at timestamp with time zone, updated_at timestamp with time zone, ai_tag_model text, ai_tag_status text, llm_review_status llm_event_review_status, llm_review_decision llm_event_review_decision, llm_review_confidence numeric, llm_review_reason text, llm_review_flags text[], llm_review_provider text, llm_review_model text, llm_review_prompt_version text, llm_reviewed_at timestamp with time zone, llm_review_error text, total_count bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
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
        ELSE replace(replace(replace(btrim(p_keyword), '\\', '\\\\'), '%', '\\%'), '_', '\\_')
      END AS escaped_kw,
      LEAST(GREATEST(COALESCE(p_limit, 50), 1), 500) AS page_size
  ),
  base AS (
    SELECT e.*
    FROM public.events e
    CROSS JOIN search_input si
    WHERE
      (p_status IS NULL OR e.status::text = p_status)
      AND (
        p_city_is_null IS NULL
        OR (p_city_is_null = true  AND e.city_id IS NULL)
        OR (p_city_is_null = false AND e.city_id IS NOT NULL)
      )
      AND (p_city_id IS NULL OR e.city_id = p_city_id)
      AND (p_llm_review_status IS NULL OR e.llm_review_status = p_llm_review_status)
      AND (p_llm_review_decision IS NULL OR e.llm_review_decision = p_llm_review_decision)
      AND (
        p_llm_reviewed IS DISTINCT FROM true
        OR (
          e.llm_reviewed_at IS NOT NULL
          AND e.llm_review_decision IS NOT NULL
          AND e.llm_review_status <> 'failed'::public.llm_event_review_status
        )
      )
      AND (
        si.kw IS NULL
        OR (
          si.tsq IS NOT NULL
          AND numnode(si.tsq) > 0
          AND e.search_vector @@ si.tsq
        )
        OR (
          si.escaped_kw IS NOT NULL
          AND (si.tsq IS NULL OR numnode(si.tsq) = 0 OR length(si.kw) < 3)
          AND (
            e.title ILIKE '%' || si.escaped_kw || '%' ESCAPE '\\'
            OR e.description ILIKE '%' || si.escaped_kw || '%' ESCAPE '\\'
          )
        )
      )
  ),
  base_count AS (
    SELECT COUNT(*)::bigint AS total_count FROM base
  ),
  page AS (
    SELECT b.*, c.total_count
    FROM base b
    CROSS JOIN base_count c
    WHERE (
      p_after_created_at IS NULL
      OR (
        p_after_id IS NULL
        AND b.created_at < p_after_created_at
      )
      OR (
        p_after_id IS NOT NULL
        AND (b.created_at, b.id) < (p_after_created_at, p_after_id)
      )
    )
    ORDER BY b.created_at DESC, b.id DESC
    LIMIT (SELECT page_size FROM search_input)
  )
  SELECT
    p.id, p.title, p.description, p.start_datetime, p.end_datetime, p.timezone,
    p.venue_name, p.address, p.city_id, p.latitude, p.longitude,
    p.age_min, p.age_max, p.price, p.is_free,
    p.source_url, p.source_name, p.source_id, p.images, p.status::text,
    p.ai_confidence, p.ai_tag_provider, p.recurrence_info, p.is_featured, p.view_count,
    p.search_vector, p.admin_locked_fields, p.admin_last_edited_at, p.admin_last_edited_by,
    p.created_at, p.updated_at, p.ai_tag_model, p.ai_tag_status,
    p.llm_review_status, p.llm_review_decision, p.llm_review_confidence, p.llm_review_reason,
    p.llm_review_flags, p.llm_review_provider, p.llm_review_model, p.llm_review_prompt_version,
    p.llm_reviewed_at, p.llm_review_error,
    p.total_count
  FROM page p;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 7. Validate the six data-integrity constraints (rows cleaned in step 1).
-- ---------------------------------------------------------------------------
ALTER TABLE public.events        VALIDATE CONSTRAINT events_age_range_chk;
ALTER TABLE public.events        VALIDATE CONSTRAINT events_lat_lng_chk;
ALTER TABLE public.events        VALIDATE CONSTRAINT events_price_chk;
ALTER TABLE public.user_profiles VALIDATE CONSTRAINT user_profiles_child_age_chk;
ALTER TABLE public.invite_codes  VALIDATE CONSTRAINT invite_codes_used_count_max_chk;
ALTER TABLE public.event_sources VALIDATE CONSTRAINT event_sources_scrape_interval_chk;

COMMIT;
