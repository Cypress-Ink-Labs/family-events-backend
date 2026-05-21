-- Increase the pg_net timeout for invoke_process_tag_queue.
--
-- pg_net defaults to 5 000 ms. process-tag-queue processes a batch of 8
-- events and, with AI tagging + geocoding, routinely takes 30–40 s.
-- The 5 s timeout caused every pg_cron tick to abort before the edge
-- function could respond, leaving all items unclaimed.
--
-- 120 000 ms (2 min) gives one full batch comfortable headroom while staying
-- well under Supabase's 150 s edge-function wall clock.

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
    url                  := v_supabase_url || '/functions/v1/process-tag-queue',
    headers              := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_service_role
    ),
    body                 := '{}'::jsonb,
    timeout_milliseconds := 120000
  );
END;
$$;

REVOKE ALL ON FUNCTION public.invoke_process_tag_queue() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.invoke_process_tag_queue() TO postgres, service_role;
