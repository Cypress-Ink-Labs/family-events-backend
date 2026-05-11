-- supabase/migrations/20260601000600_007_auto_approve.sql

-- Add auto_approve column to event_sources
ALTER TABLE public.event_sources
  ADD COLUMN IF NOT EXISTS auto_approve boolean NOT NULL DEFAULT false;

-- Bulk-toggle RPC (admin only, atomic update)
CREATE OR REPLACE FUNCTION public.admin_bulk_set_auto_approve(enable boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.event_sources SET auto_approve = enable;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_bulk_set_auto_approve(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_bulk_set_auto_approve(boolean) TO authenticated;
