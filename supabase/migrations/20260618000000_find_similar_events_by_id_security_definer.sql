-- Plan 024: Make public.find_similar_events_by_id SECURITY DEFINER.
--
-- The public wrapper was SECURITY INVOKER (see 20260601029000_*.sql). When
-- `anon`/`authenticated` call it via PostgREST, it runs as the caller and then
-- tries to invoke the `private` body the caller has no EXECUTE on, failing with
-- `42501 permission denied`. Flipping the wrapper to SECURITY DEFINER (matching
-- the private.invites_required pattern) lets the wrapper's owner reach the
-- private function while the published-only filter stays enforced in the body.
--
-- Append-only: this CREATE OR REPLACE supersedes the wrapper from 20260601029000
-- without editing that migration. It ALSO gates the source event to published in
-- the private body (defense-in-depth for the now-anon-reachable path — see below).
-- Paired rollback:
-- supabase/rollbacks/20260618000000_find_similar_events_by_id_security_definer_down.sql

-- ─── Public wrapper (now SECURITY DEFINER) ──────────────────────────────────
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
SECURITY DEFINER
SET search_path TO ''
AS $$
  SELECT * FROM private.find_similar_events_by_id(p_event_id, p_limit, p_city_id);
$$;

-- Re-apply grants after replacing the function (CREATE OR REPLACE preserves them,
-- but re-stating keeps the consumer-facing contract explicit and idempotent).
REVOKE EXECUTE ON FUNCTION public.find_similar_events_by_id(uuid, int, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.find_similar_events_by_id(uuid, int, uuid)
  TO authenticated, anon, service_role;

-- ─── Source-event visibility gate (defense in depth) ────────────────────────
-- Now that the wrapper is reachable by anon/authenticated, gate the SOURCE event
-- to published too. The original body (20260601029000) looked up the source
-- event's embedding with no status check; drafts ARE embedded
-- (list_events_needing_embeddings has no status filter), so a caller supplying an
-- unpublished event UUID could derive its published semantic neighbours +
-- distances. Joining public.events on status='published' makes an unpublished
-- source resolve to no embedding → empty result. Neighbours stay
-- published-filtered (unchanged from the original body).
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
  -- Look up the embedding ONLY for a PUBLISHED source event; empty otherwise.
  SELECT ee.embedding INTO v_embedding
  FROM public.event_embeddings ee
  JOIN public.events e ON e.id = ee.event_id
  WHERE ee.event_id = p_event_id
    AND e.status = 'published'::public.event_status;

  IF v_embedding IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT fse.*
  FROM private.find_similar_events(
    p_embedding        := v_embedding,
    p_limit            := p_limit,
    p_threshold        := 0.3,
    p_exclude_event_id := p_event_id,
    p_city_id          := p_city_id
  ) fse
  WHERE fse.status = 'published'::public.event_status;
END;
$$;
