-- supabase/migrations/20260601000600_007_auto_approve.sql

-- Add auto_approve column to event_sources
ALTER TABLE public.event_sources
  ADD COLUMN IF NOT EXISTS auto_approve boolean NOT NULL DEFAULT false;

-- Bulk-toggle RPC (admin only, atomic update)
CREATE OR REPLACE FUNCTION public.admin_bulk_set_auto_approve(enable boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  affected integer;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  UPDATE public.event_sources SET auto_approve = enable;
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

REVOKE ALL ON FUNCTION public.admin_bulk_set_auto_approve(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_bulk_set_auto_approve(boolean) TO authenticated;
