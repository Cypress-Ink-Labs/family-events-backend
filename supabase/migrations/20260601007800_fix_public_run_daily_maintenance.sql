BEGIN;

-- Update private.run_daily_maintenance to include timezone refresh + trace pruning.
-- Previously the public wrapper duplicated the private logic AND added timezone refresh,
-- while trace_retention.sql only updated the private version with trace pruning.
-- This merge ensures the private function is the single source of truth.
CREATE OR REPLACE FUNCTION "private"."run_daily_maintenance"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_event_tag_pruned          int;
  v_invite_request_pruned     int;
  v_invite_redemption_pruned  int;
  v_rec_pruned                int;
  v_ai_traces_pruned          int;
  v_extraction_traces_pruned  int;
BEGIN
  DELETE FROM public.event_tag_queue
  WHERE (status = 'dead'   AND finished_at < now() - interval '30 days')
     OR (status = 'failed' AND finished_at < now() - interval '7 days');
  GET DIAGNOSTICS v_event_tag_pruned = ROW_COUNT;

  DELETE FROM public.invite_request_attempts
  WHERE attempted_at < now() - interval '30 days';
  GET DIAGNOSTICS v_invite_request_pruned = ROW_COUNT;

  DELETE FROM public.invite_redemption_attempts
  WHERE attempted_at < now() - interval '30 days';
  GET DIAGNOSTICS v_invite_redemption_pruned = ROW_COUNT;

  DELETE FROM public.recommendation_signals
  WHERE created_at < now() - interval '90 days';
  GET DIAGNOSTICS v_rec_pruned = ROW_COUNT;

  DELETE FROM public.event_ai_traces
  WHERE created_at < now() - interval '90 days';
  GET DIAGNOSTICS v_ai_traces_pruned = ROW_COUNT;

  DELETE FROM public.source_extraction_traces
  WHERE created_at < now() - interval '90 days';
  GET DIAGNOSTICS v_extraction_traces_pruned = ROW_COUNT;

  PERFORM private.refresh_timezone_names();

  RETURN jsonb_build_object(
    'event_tag_queue_pruned',              v_event_tag_pruned,
    'invite_request_attempts_pruned',      v_invite_request_pruned,
    'invite_redemption_attempts_pruned',   v_invite_redemption_pruned,
    'recommendation_signals_pruned',       v_rec_pruned,
    'ai_traces_pruned',                    v_ai_traces_pruned,
    'extraction_traces_pruned',            v_extraction_traces_pruned,
    'timezone_names_refreshed',            true,
    'ran_at',                              now()
  );
END;
$$;

-- Replace the duplicated public wrapper with a thin SECURITY INVOKER delegate.
-- service_role has EXECUTE on private.run_daily_maintenance and USAGE on schema private
-- (granted in 20260601005600), so this call resolves correctly.
CREATE OR REPLACE FUNCTION "public"."run_daily_maintenance"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY INVOKER
    SET "search_path" TO ''
    AS $$
BEGIN
  RETURN private.run_daily_maintenance();
END;
$$;

REVOKE ALL ON FUNCTION "public"."run_daily_maintenance"() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION "public"."run_daily_maintenance"() TO service_role;

COMMENT ON FUNCTION "private"."run_daily_maintenance"() IS 'Daily prune: event_tag_queue dead/failed, invite_request_attempts, invite_redemption_attempts, recommendation_signals, event_ai_traces, source_extraction_traces. Also refreshes private.timezone_names_cache. Invoked via public.run_daily_maintenance() by the cron-db-maintenance Railway service.';
COMMENT ON FUNCTION "public"."run_daily_maintenance"() IS 'Thin SECURITY INVOKER wrapper delegating to private.run_daily_maintenance(). Called by the db-maintenance edge function (service_role).';

COMMIT;
