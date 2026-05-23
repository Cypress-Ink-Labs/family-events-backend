-- Fix: admin_update_source silently dropped processing_mode patches.
-- The admin UI sends { processing_mode, auto_approve } when a user flips
-- a source's processing mode in the Sources page; only auto_approve was
-- being applied. The dropdown then reverted on refetch because
-- processing_mode never changed. Adds the missing CASE branch so
-- processing_mode is persisted (including a cast to the enum so invalid
-- values fail loud instead of silently no-opping).

BEGIN;

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
         processing_mode = CASE WHEN patch ? 'processing_mode' THEN (patch->>'processing_mode')::public.event_processing_mode ELSE processing_mode END,
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

COMMIT;
