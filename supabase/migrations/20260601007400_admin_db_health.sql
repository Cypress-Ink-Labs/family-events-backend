BEGIN;

-- ============================================================
-- private.admin_db_health_snapshot  (SECURITY DEFINER body)
-- ============================================================
CREATE OR REPLACE FUNCTION private.admin_db_health_snapshot()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'tag_queue_by_status',
    (SELECT jsonb_object_agg(status, row_count) FROM public.event_tag_queue_summary),

    'source_queue_by_status',
    (SELECT jsonb_object_agg(status, row_count) FROM public.source_scrape_queue_summary),

    'tag_queue_oldest_pending',
    (SELECT oldest_enqueued_at FROM public.event_tag_queue_summary WHERE status = 'pending' LIMIT 1),

    'source_queue_oldest_pending',
    (SELECT oldest_enqueued_at FROM public.source_scrape_queue_summary WHERE status = 'pending' LIMIT 1),

    'tag_queue_dead',
    (SELECT COALESCE(row_count, 0) FROM public.event_tag_queue_summary WHERE status = 'dead' LIMIT 1),

    'tag_queue_failed',
    (SELECT COALESCE(row_count, 0) FROM public.event_tag_queue_summary WHERE status = 'failed' LIMIT 1),

    'source_runs_stuck_running',
    (SELECT COUNT(*) FROM public.source_runs WHERE status = 'running' AND started_at < now() - interval '15 minutes'),

    'recent_cron_runs_by_label_status',
    (
      SELECT jsonb_object_agg(
        label,
        jsonb_build_object(
          'succeeded', COUNT(*) FILTER (WHERE status = 'success'),
          'failed',    COUNT(*) FILTER (WHERE status = 'error')
        )
      )
      FROM private.railway_cron_runs
      WHERE ran_at >= now() - interval '24 hours'
      GROUP BY label
    ),

    'snapshot_at', now()
  ) INTO v_result;

  RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION private.admin_db_health_snapshot() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.admin_db_health_snapshot() TO authenticated, service_role;

-- ============================================================
-- public.admin_db_health_snapshot  (SECURITY INVOKER wrapper)
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_db_health_snapshot()
RETURNS jsonb
LANGUAGE sql
VOLATILE
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT private.admin_db_health_snapshot();
$$;

REVOKE EXECUTE ON FUNCTION public.admin_db_health_snapshot() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_db_health_snapshot() TO authenticated;

COMMIT;
