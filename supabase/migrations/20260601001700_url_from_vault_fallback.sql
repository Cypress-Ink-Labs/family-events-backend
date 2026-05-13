-- Read the Supabase project URL from vault.secrets first, then fall back to
-- the app.settings.supabase_url GUC.
-- ----------------------------------------------------------------
-- Supabase Cloud locks the `app.settings.*` GUC namespace (only superuser can
-- ALTER DATABASE ... SET app.settings.*), so the three pg_net dispatchers were
-- silently no-opping on the hosted project: notify-email never fired, and the
-- cron-driven scrape + tag workers were skipping their HTTP POST.
--
-- This migration adds a vault-first lookup keyed on 'supabase_project_url'
-- so the URL can be configured without superuser. The GUC path is preserved
-- for local-dev / CI parity (scripts/setup-local.sh still writes the GUC).
--
-- Required one-time setup on a hosted project:
--   select vault.create_secret('https://<ref>.supabase.co', 'supabase_project_url');
--   select vault.create_secret('<service-role-or-sb_secret>', 'scrape_service_role_key');

BEGIN;

-- =============================================
-- 1. private.dispatch_email_notification
-- =============================================
CREATE OR REPLACE FUNCTION private.dispatch_email_notification(p_payload jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_supabase_url  text;
  v_service_role  text;
BEGIN
  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'supabase_project_url'
  LIMIT 1;

  IF v_supabase_url IS NULL THEN
    v_supabase_url := current_setting('app.settings.supabase_url', true);
  END IF;

  SELECT decrypted_secret INTO v_service_role
  FROM vault.decrypted_secrets
  WHERE name = 'scrape_service_role_key'
  LIMIT 1;

  IF v_service_role IS NULL THEN
    v_service_role := current_setting('app.settings.service_role_key', true);
  END IF;

  IF v_supabase_url IS NULL OR v_service_role IS NULL THEN
    RAISE NOTICE 'Skipping email notification: missing supabase_url or service_role_key';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url     := v_supabase_url || '/functions/v1/notify-email',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_service_role
    ),
    body    := p_payload
  );
END;
$$;

REVOKE ALL ON FUNCTION private.dispatch_email_notification(jsonb) FROM PUBLIC;

-- =============================================
-- 2. public.invoke_scrape_source
-- =============================================
CREATE OR REPLACE FUNCTION public.invoke_scrape_source(source_uuid uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_supabase_url  text;
  v_service_role  text;
BEGIN
  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'supabase_project_url'
  LIMIT 1;

  IF v_supabase_url IS NULL THEN
    v_supabase_url := current_setting('app.settings.supabase_url', true);
  END IF;

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
  'Reads supabase_url and service-role key from vault.secrets (names:
   supabase_project_url, scrape_service_role_key) with app.settings GUC
   fallback for local-dev parity.';

-- =============================================
-- 3. public.invoke_process_tag_queue
-- =============================================
CREATE OR REPLACE FUNCTION public.invoke_process_tag_queue()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_supabase_url  text;
  v_service_role  text;
  v_reaped        int;
BEGIN
  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'supabase_project_url'
  LIMIT 1;

  IF v_supabase_url IS NULL THEN
    v_supabase_url := current_setting('app.settings.supabase_url', true);
  END IF;

  SELECT decrypted_secret INTO v_service_role
  FROM vault.decrypted_secrets
  WHERE name = 'scrape_service_role_key'
  LIMIT 1;

  IF v_service_role IS NULL THEN
    v_service_role := current_setting('app.settings.service_role_key', true);
  END IF;

  IF v_supabase_url IS NULL OR v_service_role IS NULL THEN
    RAISE NOTICE 'Skipping process-tag-queue: missing supabase_url or service_role_key';
    RETURN;
  END IF;

  v_reaped := public.reap_stuck_tag_queue_rows();
  IF v_reaped > 0 THEN
    RAISE NOTICE 'reaped % stuck tag-queue rows', v_reaped;
  END IF;

  PERFORM net.http_post(
    url     := v_supabase_url || '/functions/v1/process-tag-queue',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_service_role
    ),
    body    := '{}'::jsonb
  );
END;
$$;

REVOKE ALL ON FUNCTION public.invoke_process_tag_queue() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.invoke_process_tag_queue() TO postgres, service_role;

COMMIT;
