-- =============================================================================
-- Migration: Clear any existing invite gate GUC override
-- =============================================================================
--
-- The previous migration changed invites_required() to default to FALSE,
-- but production may already have app.settings.require_invite = 'true'
-- set at the ROLE or DATABASE level. This clears those overrides so the
-- function's default (false / open registration) takes effect.
--
-- ALTER ROLE is supported on Supabase Cloud. ALTER DATABASE is not.
-- We try both with exception handling to be safe.
-- =============================================================================

DO $$
BEGIN
  -- Clear ROLE-level override (works on Supabase Cloud)
  EXECUTE 'ALTER ROLE ' || current_user || ' RESET app.settings.require_invite';
  RAISE NOTICE 'invite gate: cleared ROLE-level GUC override';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'invite gate: could not reset ROLE-level GUC (%), skipping', SQLERRM;
END;
$$;

DO $$
BEGIN
  -- Clear DATABASE-level override (works locally, blocked on Cloud)
  EXECUTE 'ALTER DATABASE ' || current_database() || ' RESET app.settings.require_invite';
  RAISE NOTICE 'invite gate: cleared DATABASE-level GUC override';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'invite gate: could not reset DATABASE-level GUC (%), skipping', SQLERRM;
END;
$$;
