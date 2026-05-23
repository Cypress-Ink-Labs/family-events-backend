-- Guarded schema optimization migration.
-- Some environments may not yet include all LLM review or cron objects.

DO $$
BEGIN
  -- LLM review FK coverage indexes.
  IF to_regclass('public.event_llm_review_queue') IS NOT NULL THEN
    EXECUTE 'CREATE INDEX IF NOT EXISTS event_llm_review_queue_source_id_idx
             ON public.event_llm_review_queue USING btree (source_id)
             WHERE source_id IS NOT NULL';
    EXECUTE 'CREATE INDEX IF NOT EXISTS event_llm_review_queue_source_run_id_idx
             ON public.event_llm_review_queue USING btree (source_run_id)
             WHERE source_run_id IS NOT NULL';
  END IF;

  IF to_regclass('public.event_llm_review_traces') IS NOT NULL THEN
    EXECUTE 'CREATE INDEX IF NOT EXISTS event_llm_review_traces_queue_id_idx
             ON public.event_llm_review_traces USING btree (queue_id)
             WHERE queue_id IS NOT NULL';
    EXECUTE 'CREATE INDEX IF NOT EXISTS event_llm_review_traces_source_id_idx
             ON public.event_llm_review_traces USING btree (source_id)
             WHERE source_id IS NOT NULL';
    EXECUTE 'CREATE INDEX IF NOT EXISTS event_llm_review_traces_source_run_id_idx
             ON public.event_llm_review_traces USING btree (source_run_id)
             WHERE source_run_id IS NOT NULL';
  END IF;

  -- Retention and maintenance indexes.
  IF to_regclass('public.invite_request_attempts') IS NOT NULL THEN
    EXECUTE 'CREATE INDEX IF NOT EXISTS invite_request_attempts_attempted_at_idx
             ON public.invite_request_attempts USING btree (attempted_at)';
  END IF;

  IF to_regclass('public.invite_redemption_attempts') IS NOT NULL THEN
    EXECUTE 'CREATE INDEX IF NOT EXISTS invite_redemption_attempts_attempted_at_idx
             ON public.invite_redemption_attempts USING btree (attempted_at)';
  END IF;

  IF to_regclass('public.recommendation_signals') IS NOT NULL THEN
    EXECUTE 'CREATE INDEX IF NOT EXISTS recommendation_signals_created_at_idx
             ON public.recommendation_signals USING btree (created_at)';
  END IF;

  IF to_regclass('public.event_ai_traces') IS NOT NULL THEN
    EXECUTE 'CREATE INDEX IF NOT EXISTS event_ai_traces_created_at_idx
             ON public.event_ai_traces USING btree (created_at)';
  END IF;

  IF to_regclass('public.source_extraction_traces') IS NOT NULL THEN
    EXECUTE 'CREATE INDEX IF NOT EXISTS source_extraction_traces_created_at_idx
             ON public.source_extraction_traces USING btree (created_at)';
  END IF;

  IF to_regclass('public.source_runs') IS NOT NULL THEN
    EXECUTE 'CREATE INDEX IF NOT EXISTS source_runs_running_started_idx
             ON public.source_runs USING btree (started_at)
             WHERE status = ''running''';
  END IF;

  IF to_regclass('public.events') IS NOT NULL THEN
    EXECUTE 'CREATE INDEX IF NOT EXISTS events_needing_enrichment_created_idx
             ON public.events USING btree (created_at DESC, id)
             WHERE (
               latitude IS NULL
               OR longitude IS NULL
               OR images = ''[]''::jsonb
               OR jsonb_array_length(images) = 0
             )';
  END IF;
END;
$$;

DO $$
BEGIN
  -- Cache fixed helper calls in RLS predicates.
  IF EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'event_llm_review_queue'
      AND policyname = 'Admins can read event llm review queue'
  ) THEN
    EXECUTE $sql$
      ALTER POLICY "Admins can read event llm review queue"
      ON public.event_llm_review_queue
      USING ((SELECT private.is_admin()));
    $sql$;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'event_llm_review_traces'
      AND policyname = 'Admins can read event llm review traces'
  ) THEN
    EXECUTE $sql$
      ALTER POLICY "Admins can read event llm review traces"
      ON public.event_llm_review_traces
      USING ((SELECT private.is_admin()));
    $sql$;
  END IF;

  -- Restrict trigger-only or service-only public function execution.
  IF to_regprocedure('public.handle_new_user()') IS NOT NULL THEN
    EXECUTE 'REVOKE EXECUTE ON FUNCTION public.handle_new_user()
             FROM PUBLIC, anon, authenticated';
  END IF;

  IF to_regprocedure('public.prevent_role_change()') IS NOT NULL THEN
    EXECUTE 'REVOKE EXECUTE ON FUNCTION public.prevent_role_change()
             FROM PUBLIC, anon, authenticated';
  END IF;

  IF to_regprocedure('public.reset_comment_approval_for_non_admin()') IS NOT NULL THEN
    EXECUTE 'REVOKE EXECUTE ON FUNCTION public.reset_comment_approval_for_non_admin()
             FROM PUBLIC, anon, authenticated';
  END IF;

  IF to_regprocedure('public.invoke_process_tag_queue()') IS NOT NULL THEN
    EXECUTE 'REVOKE EXECUTE ON FUNCTION public.invoke_process_tag_queue()
             FROM PUBLIC, anon, authenticated';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.invoke_process_tag_queue() TO service_role';
  END IF;

  IF to_regprocedure('public.invoke_scrape_source(uuid)') IS NOT NULL THEN
    EXECUTE 'REVOKE EXECUTE ON FUNCTION public.invoke_scrape_source(uuid)
             FROM PUBLIC, anon, authenticated';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.invoke_scrape_source(uuid) TO service_role';
  END IF;

  IF to_regprocedure('public.run_due_source_scrapes()') IS NOT NULL THEN
    EXECUTE 'REVOKE EXECUTE ON FUNCTION public.run_due_source_scrapes()
             FROM PUBLIC, anon, authenticated';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.run_due_source_scrapes() TO service_role';
  END IF;

  -- Convert public is_enabled_user RPC to invoker wrapper.
  IF to_regprocedure('private.has_enabled_access()') IS NOT NULL THEN
    EXECUTE $sql$
      CREATE OR REPLACE FUNCTION public.is_enabled_user()
      RETURNS boolean
      LANGUAGE sql
      STABLE
      SECURITY INVOKER
      SET search_path TO ''
      AS $fn$
        SELECT private.has_enabled_access();
      $fn$;
    $sql$;

    EXECUTE 'REVOKE EXECUTE ON FUNCTION public.is_enabled_user() FROM PUBLIC';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.is_enabled_user()
             TO anon, authenticated, service_role';
  END IF;

  -- Convert public admin_railway_cron_run_history to invoker wrapper.
  IF to_regprocedure('private.railway_cron_run_history(text,integer)') IS NOT NULL
     AND to_regprocedure('private.is_admin()') IS NOT NULL THEN
    EXECUTE $sql$
      CREATE OR REPLACE FUNCTION private.admin_railway_cron_run_history(
        p_label text DEFAULT NULL,
        p_limit integer DEFAULT 50
      )
      RETURNS TABLE(
        id bigint,
        label text,
        status text,
        http_status integer,
        duration_s integer,
        body text,
        ran_at timestamptz
      )
      LANGUAGE plpgsql
      STABLE
      SECURITY DEFINER
      SET search_path TO ''
      AS $fn$
      BEGIN
        IF NOT private.is_admin() THEN
          RAISE EXCEPTION 'admin access required' USING ERRCODE = '42501';
        END IF;

        RETURN QUERY
        SELECT *
        FROM private.railway_cron_run_history(p_label, p_limit);
      END;
      $fn$;
    $sql$;

    EXECUTE 'REVOKE EXECUTE ON FUNCTION private.admin_railway_cron_run_history(text, integer)
             FROM PUBLIC, anon';
    EXECUTE 'GRANT EXECUTE ON FUNCTION private.admin_railway_cron_run_history(text, integer)
             TO authenticated, service_role';

    EXECUTE $sql$
      CREATE OR REPLACE FUNCTION public.admin_railway_cron_run_history(
        p_label text DEFAULT NULL,
        p_limit integer DEFAULT 50
      )
      RETURNS TABLE(
        id bigint,
        label text,
        status text,
        http_status integer,
        duration_s integer,
        body text,
        ran_at timestamptz
      )
      LANGUAGE sql
      STABLE
      SECURITY INVOKER
      SET search_path TO ''
      AS $fn$
        SELECT *
        FROM private.admin_railway_cron_run_history(p_label, p_limit);
      $fn$;
    $sql$;

    EXECUTE 'REVOKE EXECUTE ON FUNCTION public.admin_railway_cron_run_history(text, integer)
             FROM PUBLIC, anon';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_railway_cron_run_history(text, integer)
             TO authenticated, service_role';
  END IF;
END;
$$;

DO $$
BEGIN
  -- Validate existing NOT VALID constraints when present.
  IF to_regclass('public.event_sources') IS NOT NULL AND EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'event_sources_scrape_interval_chk'
      AND conrelid = to_regclass('public.event_sources')
  ) THEN
    EXECUTE 'ALTER TABLE public.event_sources
             VALIDATE CONSTRAINT event_sources_scrape_interval_chk';
  END IF;

  IF to_regclass('public.events') IS NOT NULL AND EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'events_age_range_chk'
      AND conrelid = to_regclass('public.events')
  ) THEN
    EXECUTE 'ALTER TABLE public.events
             VALIDATE CONSTRAINT events_age_range_chk';
  END IF;

  IF to_regclass('public.events') IS NOT NULL AND EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'events_lat_lng_chk'
      AND conrelid = to_regclass('public.events')
  ) THEN
    EXECUTE 'ALTER TABLE public.events
             VALIDATE CONSTRAINT events_lat_lng_chk';
  END IF;

  IF to_regclass('public.events') IS NOT NULL AND EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'events_price_chk'
      AND conrelid = to_regclass('public.events')
  ) THEN
    EXECUTE 'ALTER TABLE public.events
             VALIDATE CONSTRAINT events_price_chk';
  END IF;

  IF to_regclass('public.invite_codes') IS NOT NULL AND EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'invite_codes_used_count_max_chk'
      AND conrelid = to_regclass('public.invite_codes')
  ) THEN
    EXECUTE 'ALTER TABLE public.invite_codes
             VALIDATE CONSTRAINT invite_codes_used_count_max_chk';
  END IF;

  IF to_regclass('public.user_profiles') IS NOT NULL AND EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'user_profiles_child_age_chk'
      AND conrelid = to_regclass('public.user_profiles')
  ) THEN
    EXECUTE 'ALTER TABLE public.user_profiles
             VALIDATE CONSTRAINT user_profiles_child_age_chk';
  END IF;

  -- Add and validate LLM queue trigger type check when table exists.
  IF to_regclass('public.event_llm_review_queue') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM pg_constraint
      WHERE conname = 'event_llm_review_queue_trigger_type_check'
        AND conrelid = to_regclass('public.event_llm_review_queue')
    ) THEN
      EXECUTE $sql$
        ALTER TABLE public.event_llm_review_queue
        ADD CONSTRAINT event_llm_review_queue_trigger_type_check
        CHECK (
          trigger_type = ANY (ARRAY['import'::text, 'reclassify'::text, 'manual-review'::text])
        ) NOT VALID
      $sql$;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM pg_constraint
      WHERE conname = 'event_llm_review_queue_trigger_type_check'
        AND conrelid = to_regclass('public.event_llm_review_queue')
    ) THEN
      EXECUTE 'ALTER TABLE public.event_llm_review_queue
               VALIDATE CONSTRAINT event_llm_review_queue_trigger_type_check';
    END IF;
  END IF;
END;
$$;

DO $$
BEGIN
  -- Enable RLS on private cron state tables when present.
  IF to_regclass('private.railway_cron_runs') IS NOT NULL THEN
    EXECUTE 'ALTER TABLE private.railway_cron_runs ENABLE ROW LEVEL SECURITY';
  END IF;

  IF to_regclass('private.cron_enabled') IS NOT NULL THEN
    EXECUTE 'ALTER TABLE private.cron_enabled ENABLE ROW LEVEL SECURITY';
  END IF;
END;
$$;
