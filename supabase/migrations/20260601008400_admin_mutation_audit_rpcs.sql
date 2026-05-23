CREATE OR REPLACE FUNCTION private.admin_set_user_access(
  p_user_id uuid,
  p_is_enabled boolean,
  p_disabled_reason text DEFAULT NULL
) RETURNS public.user_access
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  before_row public.user_access%ROWTYPE;
  updated_row public.user_access%ROWTYPE;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_USER_ACCESS_ADMIN_REQUIRED';
  END IF;

  IF p_user_id = auth.uid() AND NOT p_is_enabled THEN
    RAISE EXCEPTION 'ADMIN_USER_ACCESS_SELF_DISABLE';
  END IF;

  SELECT *
    INTO before_row
    FROM public.user_access
   WHERE user_id = p_user_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ADMIN_USER_ACCESS_NOT_FOUND';
  END IF;

  UPDATE public.user_access
     SET is_enabled = p_is_enabled,
         enabled_at = CASE
           WHEN p_is_enabled THEN COALESCE(public.user_access.enabled_at, now())
           ELSE public.user_access.enabled_at
         END,
         disabled_at = CASE WHEN p_is_enabled THEN NULL ELSE now() END,
         disabled_reason = CASE
           WHEN p_is_enabled THEN NULL
           ELSE NULLIF(btrim(COALESCE(p_disabled_reason, '')), '')
         END,
         updated_at = now()
   WHERE user_id = p_user_id
   RETURNING * INTO updated_row;

  INSERT INTO public.admin_audit_log (admin_user_id, action, target_type, target_id, metadata)
  VALUES (
    auth.uid(),
    CASE WHEN p_is_enabled THEN 'user_access.enable' ELSE 'user_access.disable' END,
    'user_access',
    p_user_id,
    jsonb_build_object(
      'previous', to_jsonb(before_row),
      'is_enabled', p_is_enabled,
      'disabled_reason', updated_row.disabled_reason
    )
  );

  RETURN updated_row;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_user_access(
  p_user_id uuid,
  p_is_enabled boolean,
  p_disabled_reason text DEFAULT NULL
) RETURNS public.user_access
LANGUAGE sql
SET search_path TO ''
AS $$
  SELECT * FROM private.admin_set_user_access(p_user_id, p_is_enabled, p_disabled_reason);
$$;

CREATE OR REPLACE FUNCTION private.admin_set_event_status(
  p_event_id uuid,
  p_status text
) RETURNS public.events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
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
     SET status = p_status,
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
$$;

CREATE OR REPLACE FUNCTION public.admin_set_event_status(
  p_event_id uuid,
  p_status text
) RETURNS public.events
LANGUAGE sql
SET search_path TO ''
AS $$
  SELECT * FROM private.admin_set_event_status(p_event_id, p_status);
$$;

CREATE OR REPLACE FUNCTION private.admin_batch_set_event_status(
  p_event_ids uuid[],
  p_status text
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
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
     SET status = p_status,
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
$$;

CREATE OR REPLACE FUNCTION public.admin_batch_set_event_status(
  p_event_ids uuid[],
  p_status text
) RETURNS integer
LANGUAGE sql
SET search_path TO ''
AS $$
  SELECT private.admin_batch_set_event_status(p_event_ids, p_status);
$$;

CREATE OR REPLACE FUNCTION private.admin_delete_events(
  p_event_ids uuid[]
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  affected integer;
  previous_rows jsonb;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_EVENT_ADMIN_REQUIRED';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(e) ORDER BY e.id), '[]'::jsonb)
    INTO previous_rows
    FROM public.events e
   WHERE e.id = ANY (COALESCE(p_event_ids, '{}'::uuid[]));

  DELETE FROM public.events
   WHERE id = ANY (COALESCE(p_event_ids, '{}'::uuid[]));

  GET DIAGNOSTICS affected = ROW_COUNT;

  INSERT INTO public.admin_audit_log (admin_user_id, action, target_type, metadata)
  VALUES (
    auth.uid(),
    'event.delete',
    'events',
    jsonb_build_object(
      'event_ids', to_jsonb(COALESCE(p_event_ids, '{}'::uuid[])),
      'affected_count', affected,
      'previous', previous_rows
    )
  );

  RETURN affected;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_events(
  p_event_ids uuid[]
) RETURNS integer
LANGUAGE sql
SET search_path TO ''
AS $$
  SELECT private.admin_delete_events(p_event_ids);
$$;

CREATE OR REPLACE FUNCTION private.admin_create_source(
  p_source jsonb
) RETURNS public.event_sources
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  source_payload jsonb := COALESCE(p_source, '{}'::jsonb);
  created_row public.event_sources%ROWTYPE;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_SOURCE_ADMIN_REQUIRED';
  END IF;

  IF NULLIF(btrim(source_payload->>'name'), '') IS NULL THEN
    RAISE EXCEPTION 'ADMIN_SOURCE_NAME_REQUIRED';
  END IF;

  IF NULLIF(btrim(source_payload->>'url'), '') IS NULL THEN
    RAISE EXCEPTION 'ADMIN_SOURCE_URL_REQUIRED';
  END IF;

  INSERT INTO public.event_sources (
    name,
    url,
    source_type,
    extraction_mode,
    city_id,
    is_active,
    auto_approve,
    scrape_interval_hours,
    last_scraped_at,
    last_status,
    error_count,
    notes,
    date_window_days
  )
  VALUES (
    btrim(source_payload->>'name'),
    btrim(source_payload->>'url'),
    COALESCE(NULLIF(btrim(source_payload->>'source_type'), ''), 'website'),
    COALESCE(NULLIF(btrim(source_payload->>'extraction_mode'), ''), 'deterministic')::public.source_extraction_mode,
    CASE
      WHEN source_payload ? 'city_id' AND jsonb_typeof(source_payload->'city_id') <> 'null' AND NULLIF(btrim(source_payload->>'city_id'), '') IS NOT NULL
        THEN (source_payload->>'city_id')::uuid
      ELSE NULL
    END,
    COALESCE((source_payload->>'is_active')::boolean, true),
    COALESCE((source_payload->>'auto_approve')::boolean, false),
    COALESCE((source_payload->>'scrape_interval_hours')::integer, 24),
    CASE
      WHEN source_payload ? 'last_scraped_at' AND jsonb_typeof(source_payload->'last_scraped_at') <> 'null'
        THEN (source_payload->>'last_scraped_at')::timestamptz
      ELSE NULL
    END,
    COALESCE(NULLIF(btrim(source_payload->>'last_status'), ''), 'pending'),
    COALESCE((source_payload->>'error_count')::integer, 0),
    CASE
      WHEN source_payload ? 'notes' AND jsonb_typeof(source_payload->'notes') <> 'null'
        THEN source_payload->>'notes'
      ELSE NULL
    END,
    CASE
      WHEN source_payload ? 'date_window_days' AND jsonb_typeof(source_payload->'date_window_days') <> 'null'
        THEN (source_payload->>'date_window_days')::integer
      ELSE NULL
    END
  )
  RETURNING * INTO created_row;

  INSERT INTO public.admin_audit_log (admin_user_id, action, target_type, target_id, metadata)
  VALUES (
    auth.uid(),
    'source.create',
    'event_source',
    created_row.id,
    jsonb_build_object('source', to_jsonb(created_row))
  );

  RETURN created_row;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_create_source(
  p_source jsonb
) RETURNS public.event_sources
LANGUAGE sql
SET search_path TO ''
AS $$
  SELECT * FROM private.admin_create_source(p_source);
$$;

CREATE OR REPLACE FUNCTION private.admin_update_source(
  p_source_id uuid,
  p_patch jsonb
) RETURNS public.event_sources
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  patch jsonb := COALESCE(p_patch, '{}'::jsonb);
  before_row public.event_sources%ROWTYPE;
  updated_row public.event_sources%ROWTYPE;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_SOURCE_ADMIN_REQUIRED';
  END IF;

  IF patch ? 'name' AND NULLIF(btrim(patch->>'name'), '') IS NULL THEN
    RAISE EXCEPTION 'ADMIN_SOURCE_NAME_REQUIRED';
  END IF;

  IF patch ? 'url' AND NULLIF(btrim(patch->>'url'), '') IS NULL THEN
    RAISE EXCEPTION 'ADMIN_SOURCE_URL_REQUIRED';
  END IF;

  SELECT *
    INTO before_row
    FROM public.event_sources
   WHERE id = p_source_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ADMIN_SOURCE_NOT_FOUND';
  END IF;

  UPDATE public.event_sources
     SET name = CASE WHEN patch ? 'name' THEN btrim(patch->>'name') ELSE name END,
         url = CASE WHEN patch ? 'url' THEN btrim(patch->>'url') ELSE url END,
         source_type = CASE WHEN patch ? 'source_type' THEN patch->>'source_type' ELSE source_type END,
         extraction_mode = CASE WHEN patch ? 'extraction_mode' THEN (patch->>'extraction_mode')::public.source_extraction_mode ELSE extraction_mode END,
         city_id = CASE
           WHEN patch ? 'city_id' AND jsonb_typeof(patch->'city_id') = 'null' THEN NULL
           WHEN patch ? 'city_id' AND NULLIF(btrim(patch->>'city_id'), '') IS NULL THEN NULL
           WHEN patch ? 'city_id' THEN (patch->>'city_id')::uuid
           ELSE city_id
         END,
         is_active = CASE WHEN patch ? 'is_active' THEN (patch->>'is_active')::boolean ELSE is_active END,
         auto_approve = CASE WHEN patch ? 'auto_approve' THEN (patch->>'auto_approve')::boolean ELSE auto_approve END,
         scrape_interval_hours = CASE WHEN patch ? 'scrape_interval_hours' THEN (patch->>'scrape_interval_hours')::integer ELSE scrape_interval_hours END,
         last_scraped_at = CASE
           WHEN patch ? 'last_scraped_at' AND jsonb_typeof(patch->'last_scraped_at') = 'null' THEN NULL
           WHEN patch ? 'last_scraped_at' THEN (patch->>'last_scraped_at')::timestamptz
           ELSE last_scraped_at
         END,
         last_status = CASE
           WHEN patch ? 'last_status' AND jsonb_typeof(patch->'last_status') = 'null' THEN NULL
           WHEN patch ? 'last_status' THEN patch->>'last_status'
           ELSE last_status
         END,
         error_count = CASE WHEN patch ? 'error_count' THEN (patch->>'error_count')::integer ELSE error_count END,
         notes = CASE
           WHEN patch ? 'notes' AND jsonb_typeof(patch->'notes') = 'null' THEN NULL
           WHEN patch ? 'notes' THEN patch->>'notes'
           ELSE notes
         END,
         date_window_days = CASE
           WHEN patch ? 'date_window_days' AND jsonb_typeof(patch->'date_window_days') = 'null' THEN NULL
           WHEN patch ? 'date_window_days' THEN (patch->>'date_window_days')::integer
           ELSE date_window_days
         END,
         updated_at = now()
   WHERE id = p_source_id
   RETURNING * INTO updated_row;

  INSERT INTO public.admin_audit_log (admin_user_id, action, target_type, target_id, metadata)
  VALUES (
    auth.uid(),
    'source.update',
    'event_source',
    p_source_id,
    jsonb_build_object('previous', to_jsonb(before_row), 'patch', patch)
  );

  RETURN updated_row;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_update_source(
  p_source_id uuid,
  p_patch jsonb
) RETURNS public.event_sources
LANGUAGE sql
SET search_path TO ''
AS $$
  SELECT * FROM private.admin_update_source(p_source_id, p_patch);
$$;

REVOKE EXECUTE ON FUNCTION private.admin_set_user_access(uuid, boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.admin_set_user_access(uuid, boolean, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_set_user_access(uuid, boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_user_access(uuid, boolean, text) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION private.admin_set_event_status(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.admin_set_event_status(uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_set_event_status(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_event_status(uuid, text) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION private.admin_batch_set_event_status(uuid[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.admin_batch_set_event_status(uuid[], text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_batch_set_event_status(uuid[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_batch_set_event_status(uuid[], text) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION private.admin_delete_events(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.admin_delete_events(uuid[]) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_delete_events(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_delete_events(uuid[]) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION private.admin_create_source(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.admin_create_source(jsonb) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_create_source(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_source(jsonb) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION private.admin_update_source(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.admin_update_source(uuid, jsonb) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_update_source(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_update_source(uuid, jsonb) TO authenticated, service_role;
