-- Rollback for 20260601021000_admin_event_decisions.sql
-- Reverts:
--   - public.admin_event_decisions table (indexes, RLS policies, grants)
--   - private.admin_update_event body (added p_decision_reason param + decision INSERT)
--   - public.admin_update_event wrapper (added p_decision_reason param)
--   - private.admin_update_event_status body (added decision INSERT + enum cast on SET)
-- Prior bodies sourced from 20260601000000_schema_baseline.sql.
-- Data-loss caveat: DROPPING admin_event_decisions DESTROYS all recorded
--   admin decision history — irreversible.

BEGIN;

-- 1. Drop the new public wrapper that added p_decision_reason.
DROP FUNCTION IF EXISTS public.admin_update_event(uuid, jsonb, uuid[], boolean, text);

-- 2. Drop the new private body that added p_decision_reason.
DROP FUNCTION IF EXISTS private.admin_update_event(uuid, jsonb, uuid[], boolean, text);

-- 3. Drop admin_event_decisions table (cascades policies and indexes).
-- WARNING: destroys all recorded admin decision data.
DROP TABLE IF EXISTS public.admin_event_decisions;

-- 4. Restore private.admin_update_event to its pre-021000 body (no decision_reason).
-- Prior body sourced from 20260601000000_schema_baseline.sql lines 2034-2176.
CREATE OR REPLACE FUNCTION private.admin_update_event(
  p_event_id uuid,
  p_patch jsonb,
  p_tag_ids uuid[],
  p_lock_edited_fields boolean DEFAULT true
)
RETURNS public.events
LANGUAGE plpgsql
SET search_path TO ''
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
         status = CASE WHEN patch ? 'status' THEN (patch->>'status')::public.event_status ELSE status END,
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

-- 5. Restore public.admin_update_event wrapper (no p_decision_reason).
-- Prior body sourced from 20260601000000_schema_baseline.sql lines 3539-3544.
CREATE OR REPLACE FUNCTION public.admin_update_event(
  p_event_id uuid,
  p_patch jsonb,
  p_tag_ids uuid[],
  p_lock_edited_fields boolean DEFAULT true
)
RETURNS public.events
LANGUAGE sql
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT * FROM private.admin_update_event(p_event_id, p_patch, p_tag_ids, p_lock_edited_fields);
$$;

REVOKE ALL ON FUNCTION public.admin_update_event(uuid, jsonb, uuid[], boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_update_event(uuid, jsonb, uuid[], boolean)
  TO authenticated, service_role;

-- 6. Restore private.admin_update_event_status to its pre-021000 body.
-- Prior body sourced from 20260601017000_event_status_enum_and_validate_checks.sql UP,
-- lines 263-320 (enum-era version: SET status = p_status::public.event_status).
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
$function$
;

COMMIT;
