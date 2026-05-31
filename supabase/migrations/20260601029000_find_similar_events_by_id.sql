-- S05/T02: Add event_id-based wrapper for find_similar_events
-- Looks up the event's embedding and delegates to private.find_similar_events.
-- Returns empty set if the event has no embedding.
-- Follows private body + public wrapper pattern.

-- ─── Private body (SECURITY DEFINER) ────────────────────────────────────────
CREATE OR REPLACE FUNCTION private.find_similar_events_by_id(
  p_event_id uuid,
  p_limit    int DEFAULT 5,
  p_city_id  uuid DEFAULT NULL
)
RETURNS TABLE (
  event_id        uuid,
  title           text,
  status          public.event_status,
  cosine_distance float,
  source_id       uuid,
  city_id         uuid
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_embedding extensions.vector(1536);
BEGIN
  -- Look up the event's embedding; return empty if none exists
  SELECT ee.embedding INTO v_embedding
  FROM public.event_embeddings ee
  WHERE ee.event_id = p_event_id;

  IF v_embedding IS NULL THEN
    RETURN;
  END IF;

  -- Delegate to existing private.find_similar_events, excluding the source event
  RETURN QUERY
  SELECT fse.*
  FROM private.find_similar_events(
    p_embedding        := v_embedding,
    p_limit            := p_limit,
    p_threshold        := 0.3,
    p_exclude_event_id := p_event_id,
    p_city_id          := p_city_id
  ) fse
  -- Only return published events for consumer-facing use
  WHERE fse.status = 'published'::public.event_status;
END;
$$;

COMMENT ON FUNCTION private.find_similar_events_by_id IS
  'Looks up an event''s embedding and returns similar published events. '
  'Returns empty set if the event has no embedding.';

REVOKE EXECUTE ON FUNCTION private.find_similar_events_by_id(uuid, int, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.find_similar_events_by_id(uuid, int, uuid)
  TO service_role;

-- ─── Public wrapper (SECURITY INVOKER) ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.find_similar_events_by_id(
  p_event_id uuid,
  p_limit    int DEFAULT 5,
  p_city_id  uuid DEFAULT NULL
)
RETURNS TABLE (
  event_id        uuid,
  title           text,
  status          public.event_status,
  cosine_distance float,
  source_id       uuid,
  city_id         uuid
)
LANGUAGE sql
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT * FROM private.find_similar_events_by_id(p_event_id, p_limit, p_city_id);
$$;

-- Consumer-facing: grant to authenticated and anon for event detail page
REVOKE EXECUTE ON FUNCTION public.find_similar_events_by_id(uuid, int, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.find_similar_events_by_id(uuid, int, uuid)
  TO authenticated, anon, service_role;
