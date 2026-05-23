BEGIN;

/*
  Supabase safe-update guard rejects table-wide UPDATEs without a WHERE clause.
  The admin bulk processing-mode RPCs intentionally target all sources, so we
  keep semantics while satisfying the guard with an explicit predicate.
*/

CREATE OR REPLACE FUNCTION private.admin_bulk_set_processing_mode(
  p_mode public.event_processing_mode
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  affected integer;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  UPDATE public.event_sources
  SET processing_mode = p_mode,
      auto_approve = (p_mode = 'auto_approve'::public.event_processing_mode),
      updated_at = now()
  WHERE id IS NOT NULL;
  GET DIAGNOSTICS affected = ROW_COUNT;

  INSERT INTO public.admin_audit_log (admin_user_id, action, target_type, metadata)
  VALUES (
    auth.uid(),
    'bulk_set_processing_mode',
    'event_sources',
    jsonb_build_object('processing_mode', p_mode::text, 'affected_count', affected)
  );
END;
$$;

CREATE OR REPLACE FUNCTION private.admin_bulk_set_auto_approve(enable boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  affected integer;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  UPDATE public.event_sources
  SET auto_approve = enable,
      processing_mode = CASE
        WHEN enable THEN 'auto_approve'::public.event_processing_mode
        ELSE 'manual_review'::public.event_processing_mode
      END,
      updated_at = now()
  WHERE id IS NOT NULL;
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

COMMIT;
