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
-- without editing that migration. The private body is unchanged. Paired rollback:
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
