-- Tighten: authenticated users should not call private fn directly.
-- The public wrapper already enforces is_admin(); direct grant is unnecessary.
-- Wrapped in DO block: REVOKE has no IF EXISTS syntax.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'private' AND p.proname = 'upsert_ai_feature_config'
  ) THEN
    REVOKE EXECUTE ON FUNCTION private.upsert_ai_feature_config(text, text, bool)
      FROM authenticated;
  END IF;
END $$;
