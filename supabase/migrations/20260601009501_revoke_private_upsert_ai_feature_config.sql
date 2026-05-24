-- Tighten: authenticated users should not call private fn directly.
-- The public wrapper already enforces is_admin(); direct grant is unnecessary.
REVOKE EXECUTE ON FUNCTION private.upsert_ai_feature_config(text, text, bool)
  FROM authenticated;
