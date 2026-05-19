-- admin_delete_rating: lets admins remove any rating regardless of ownership.
-- The default RLS policy on public.ratings only allows owners to delete; admins
-- previously could not delete other users' ratings via direct DELETE.
--
-- Follows the private body + public wrapper convention so Supabase advisor
-- lints 0028/0029 stay clean. private.admin_delete_rating performs the
-- privileged write under SECURITY DEFINER; public.admin_delete_rating is a
-- thin SECURITY INVOKER wrapper.

BEGIN;

CREATE OR REPLACE FUNCTION private.admin_delete_rating(p_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
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

REVOKE ALL ON FUNCTION private.admin_delete_rating(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.admin_delete_rating(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_delete_rating(p_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.admin_delete_rating(p_id);
$$;

REVOKE EXECUTE ON FUNCTION public.admin_delete_rating(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_delete_rating(uuid) TO authenticated, service_role;

COMMIT;
