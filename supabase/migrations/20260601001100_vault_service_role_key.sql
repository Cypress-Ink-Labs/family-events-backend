-- Phase 3f: move the scrape-source service role key out of a Postgres GUC
-- and into vault.secrets so it cannot leak via current_setting() / pg_settings.
--
-- invoke_scrape_source now reads from vault.decrypted_secrets first and falls
-- back to the GUC for backward compatibility with existing local-dev / CI
-- setups (scripts/setup-local.sh writes the GUC). Operators in production
-- should:
--   1. Run `INSERT INTO vault.secrets (name, secret) VALUES
--      ('scrape_service_role_key', '<actual-key>')` once.
--   2. Optionally `ALTER DATABASE postgres RESET "app.settings.service_role_key"`
--      to remove the GUC fallback.

BEGIN;

CREATE OR REPLACE FUNCTION public.invoke_scrape_source(source_uuid uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_supabase_url   text;
  v_service_role   text;
BEGIN
  v_supabase_url := current_setting('app.settings.supabase_url', true);

  -- Prefer vault.secrets so the key isn't readable via current_setting() from
  -- any future SECURITY INVOKER context. Falls back to the GUC for backward
  -- compatibility with local-dev setups that haven't been migrated yet.
  SELECT decrypted_secret INTO v_service_role
  FROM vault.decrypted_secrets
  WHERE name = 'scrape_service_role_key'
  LIMIT 1;

  IF v_service_role IS NULL THEN
    v_service_role := current_setting('app.settings.service_role_key', true);
  END IF;

  IF v_supabase_url IS NULL OR v_service_role IS NULL THEN
    RAISE NOTICE 'Skipping scrape: no supabase_url or service_role_key configured (vault or app.settings)';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url     := v_supabase_url || '/functions/v1/scrape-source',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_service_role
    ),
    body    := jsonb_build_object('source_id', source_uuid)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.invoke_scrape_source(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.invoke_scrape_source(uuid) TO postgres, service_role;

COMMENT ON FUNCTION public.invoke_scrape_source(uuid) IS
  'Reads the service role key from vault.secrets (name: scrape_service_role_key)
   with a fallback to app.settings.service_role_key for backward compatibility.';

COMMIT;
