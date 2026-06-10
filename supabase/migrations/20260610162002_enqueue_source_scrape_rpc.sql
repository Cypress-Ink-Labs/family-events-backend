CREATE OR REPLACE FUNCTION private.enqueue_source_scrape(
  p_source_id uuid,
  p_trigger_type text DEFAULT 'manual'
)
RETURNS TABLE(queue_id bigint, deduped boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_inserted_id bigint;
  v_existing_id bigint;
BEGIN
  IF p_trigger_type IS NULL
    OR p_trigger_type <> ALL (ARRAY['manual', 'scheduled', 'bulk', 'retry'])
  THEN
    RAISE EXCEPTION 'invalid source scrape trigger type: %', p_trigger_type
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.source_scrape_queue (source_id, trigger_type)
  VALUES (p_source_id, p_trigger_type)
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_inserted_id;

  IF v_inserted_id IS NOT NULL THEN
    queue_id := v_inserted_id;
    deduped := false;
    RETURN NEXT;
    RETURN;
  END IF;

  SELECT id
  INTO v_existing_id
  FROM public.source_scrape_queue
  WHERE source_id = p_source_id
    AND status IN ('pending', 'processing', 'retrying')
  ORDER BY enqueued_at ASC, id ASC
  LIMIT 1;

  queue_id := v_existing_id;
  deduped := true;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION private.enqueue_source_scrape(uuid, text) FROM PUBLIC;
GRANT ALL ON FUNCTION private.enqueue_source_scrape(uuid, text) TO service_role;

CREATE OR REPLACE FUNCTION public.enqueue_source_scrape(
  p_source_id uuid,
  p_trigger_type text DEFAULT 'manual'
)
RETURNS TABLE(queue_id bigint, deduped boolean)
LANGUAGE sql
SECURITY DEFINER
SET search_path TO ''
AS $$
  SELECT *
  FROM private.enqueue_source_scrape(p_source_id, p_trigger_type);
$$;

REVOKE ALL ON FUNCTION public.enqueue_source_scrape(uuid, text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.enqueue_source_scrape(uuid, text) TO service_role;
