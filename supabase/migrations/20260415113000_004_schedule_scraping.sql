/*
  # Schedule automated source scraping

  ## What this migration does
  - Enables `pg_cron` and `pg_net`
  - Adds `public.invoke_scrape_source(source_id uuid)` helper
  - Adds `public.run_due_source_scrapes()` hourly sweep
  - Schedules cron job `scrape-due-sources-hourly`

  ## Required runtime settings
  Set both database settings so pg_net can invoke the edge function:

  - app.settings.supabase_url
  - app.settings.service_role_key
*/

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

CREATE OR REPLACE FUNCTION public.invoke_scrape_source(source_uuid uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  supabase_url text := current_setting('app.settings.supabase_url', true);
  service_role_key text := current_setting('app.settings.service_role_key', true);
BEGIN
  IF supabase_url IS NULL OR service_role_key IS NULL THEN
    RAISE NOTICE 'Skipping scrape invocation because app.settings.supabase_url/service_role_key are not set';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url := supabase_url || '/functions/v1/scrape-source',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || service_role_key
    ),
    body := jsonb_build_object('source_id', source_uuid)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.run_due_source_scrapes()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  source_row record;
BEGIN
  FOR source_row IN
    SELECT id
    FROM public.event_sources
    WHERE is_active = true
      AND (
        last_scraped_at IS NULL
        OR last_scraped_at + make_interval(hours => scrape_interval_hours) <= now()
      )
  LOOP
    PERFORM public.invoke_scrape_source(source_row.id);
  END LOOP;
END;
$$;

DO $$
BEGIN
  BEGIN
    PERFORM cron.unschedule('scrape-due-sources-hourly');
  EXCEPTION
    WHEN OTHERS THEN
      NULL;
  END;

  PERFORM cron.schedule(
    'scrape-due-sources-hourly',
    '0 * * * *',
    $sql$SELECT public.run_due_source_scrapes();$sql$
  );
END
$$;
