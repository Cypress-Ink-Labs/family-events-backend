-- Add admin_delete_user RPC to permanently delete invited user accounts from the access admin UI.
-- Follows private + public wrapper pattern for SECURITY DEFINER RPCs.
-- Deletes from auth.users (ON DELETE CASCADE removes profiles, user_access, auth children, app data).
-- Prevents self-delete and deleting other admin-role accounts.
-- Audits the action to admin_audit_log with snapshots of access/profile.

CREATE OR REPLACE FUNCTION private.admin_delete_user(
  p_user_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  before_access  public.user_access%ROWTYPE;
  before_profile public.user_profiles%ROWTYPE;
  target_role    text;
  affected       integer;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_USER_ACCESS_ADMIN_REQUIRED';
  END IF;

  IF p_user_id = auth.uid() THEN
    RAISE EXCEPTION 'ADMIN_USER_ACCESS_SELF_DELETE';
  END IF;

  -- Snapshot profile/access for audit (before any delete)
  SELECT * INTO before_access FROM public.user_access WHERE user_id = p_user_id;
  SELECT * INTO before_profile FROM public.user_profiles WHERE id = p_user_id;
  SELECT role INTO target_role FROM public.user_profiles WHERE id = p_user_id;

  IF target_role = 'admin' THEN
    RAISE EXCEPTION 'ADMIN_USER_ACCESS_CANNOT_DELETE_ADMIN';
  END IF;

  -- Cascade delete the entire account (auth.users is the root)
  DELETE FROM auth.users WHERE id = p_user_id;
  GET DIAGNOSTICS affected = ROW_COUNT;

  IF affected = 0 THEN
    RAISE EXCEPTION 'ADMIN_USER_ACCESS_NOT_FOUND';
  END IF;

  INSERT INTO public.admin_audit_log (admin_user_id, action, target_type, target_id, metadata)
  VALUES (
    auth.uid(),
    'user.delete',
    'user_access',
    p_user_id,
    jsonb_build_object(
      'previous_access', to_jsonb(before_access),
      'previous_profile', to_jsonb(before_profile)
    )
  );
END;
$$;

ALTER FUNCTION private.admin_delete_user(uuid) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION public.admin_delete_user(
  p_user_id uuid
) RETURNS void
LANGUAGE sql
SET search_path TO ''
AS $$
  SELECT private.admin_delete_user(p_user_id);
$$;

ALTER FUNCTION public.admin_delete_user(uuid) OWNER TO "postgres";

REVOKE ALL ON FUNCTION private.admin_delete_user(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.admin_delete_user(uuid) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.admin_delete_user(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_delete_user(uuid) TO authenticated, service_role;
