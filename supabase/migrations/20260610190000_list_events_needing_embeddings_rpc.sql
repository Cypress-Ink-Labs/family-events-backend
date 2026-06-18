-- Plan 005: Replace NOT-IN exclusion with LEFT JOIN RPC for un-embedded events.
-- A single indexed LEFT JOIN on event_embeddings is O(events) server-side,
-- whereas the old approach serialized all embedded IDs into a request filter,
-- growing unbounded as the embedded set grows.

CREATE OR REPLACE FUNCTION public.list_events_needing_embeddings(p_limit int DEFAULT 50)
RETURNS TABLE (id uuid, title text, description text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $$
  SELECT e.id, e.title, e.description
  FROM public.events e
  LEFT JOIN public.event_embeddings ee ON ee.event_id = e.id
  WHERE ee.event_id IS NULL
  ORDER BY e.created_at ASC
  LIMIT GREATEST(1, LEAST(p_limit, 500));
$$;

REVOKE EXECUTE ON FUNCTION public.list_events_needing_embeddings(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_events_needing_embeddings(int) TO service_role;
