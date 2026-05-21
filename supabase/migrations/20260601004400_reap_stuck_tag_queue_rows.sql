CREATE OR REPLACE FUNCTION public.reap_stuck_tag_queue_rows()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_count int;
BEGIN
  UPDATE public.event_tag_queue
  SET status = 'pending',
      started_at = NULL,
      last_error = coalesce(last_error, 'reaped after stuck in processing')
  WHERE status = 'processing'
    AND (
      started_at IS NULL
      OR started_at < now() - interval '15 minutes'
    );

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.reap_stuck_tag_queue_rows() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reap_stuck_tag_queue_rows() TO service_role;
