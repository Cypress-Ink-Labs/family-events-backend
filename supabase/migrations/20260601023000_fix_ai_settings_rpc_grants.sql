-- ============================================================================
-- Fix AI Settings RPC grant chain
-- ============================================================================
-- public.upsert_ai_feature_config is a SECURITY INVOKER wrapper around
-- private.upsert_ai_feature_config. Authenticated admins therefore need EXECUTE
-- on the private body as well as the public wrapper, otherwise saves fail at
-- the nested function call before the admin check can run.
-- ============================================================================

BEGIN;

REVOKE EXECUTE ON FUNCTION private.upsert_ai_feature_config(text, text, bool)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.upsert_ai_feature_config(text, text, bool)
  TO authenticated, service_role;

DO $$
BEGIN
  IF NOT has_function_privilege(
    'authenticated',
    'public.upsert_ai_feature_config(text, text, bool)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'authenticated missing EXECUTE on public.upsert_ai_feature_config';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'private.upsert_ai_feature_config(text, text, bool)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'authenticated missing EXECUTE on private.upsert_ai_feature_config';
  END IF;
END $$;

COMMIT;
