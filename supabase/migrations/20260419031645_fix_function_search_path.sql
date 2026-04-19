/*
  # Fix function_search_path_mutable advisor warnings

  Sets an explicit empty `search_path` on the flagged functions and fully
  qualifies object references so they cannot be hijacked via a mutable
  search_path.

  Affected functions:
  - public.invoke_scrape_source(uuid)   [SECURITY DEFINER]
  - public.run_due_source_scrapes()     [SECURITY DEFINER]
  - public.update_event_search_vector() [trigger]
*/

CREATE OR REPLACE FUNCTION public.invoke_scrape_source(source_uuid uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
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
SET search_path = ''
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

CREATE OR REPLACE FUNCTION public.update_event_search_vector()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.search_vector := to_tsvector('english',
    coalesce(NEW.title, '') || ' ' ||
    coalesce(NEW.description, '') || ' ' ||
    coalesce(NEW.venue_name, '') || ' ' ||
    coalesce(NEW.address, '')
  );
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;
/*
  No-op migration.

  This version was created during advisor cleanup and already applied to the
  local migration history. Keep the file so future environments can replay the
  same migration chain without drift.
*/
