BEGIN;

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

  RETURN jsonb_build_object(
    'event_tag_queue_pruned',              v_event_tag_pruned,
    'invite_request_attempts_pruned',      v_invite_request_pruned,
    'invite_redemption_attempts_pruned',   v_invite_redemption_pruned,
    'recommendation_signals_pruned',       v_rec_pruned,
    'ai_traces_pruned',                    v_ai_traces_pruned,
    'extraction_traces_pruned',            v_extraction_traces_pruned,
    'ran_at',                              now()
  );
END;
$$;

COMMIT;
