-- Fix invoke_process_tag_queue to read supabase_url from vault
-- (Supabase Cloud blocks ALTER DATABASE SET app.settings.*, so the GUC is
-- always NULL in hosted projects. Read from vault.decrypted_secrets first,
-- consistent with the pattern used by dispatch_email_notification.)
--
-- Also creates the missing process-tag-queue pg_cron job that was never
-- scheduled in production.

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
  -- Vault first (works on Supabase Cloud), GUC fallback (works locally).
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

  -- Reap stuck rows BEFORE invoking the worker so newly-pending rows are
  -- visible to the same pass.
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

-- Schedule process-tag-queue every minute if not already scheduled.
DO $$
BEGIN
  BEGIN
    PERFORM cron.unschedule('process-tag-queue');
  EXCEPTION
    WHEN undefined_object THEN NULL;
    WHEN OTHERS THEN
      RAISE WARNING 'Unexpected error unscheduling process-tag-queue: %', SQLERRM;
  END;
  PERFORM cron.schedule(
    'process-tag-queue',
    '* * * * *',
    $sql$SELECT public.invoke_process_tag_queue();$sql$
  );
END $$;
