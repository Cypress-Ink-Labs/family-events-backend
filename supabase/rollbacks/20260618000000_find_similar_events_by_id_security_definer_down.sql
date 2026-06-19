-- Rollback for 20260618000000_find_similar_events_by_id_security_definer.sql
--
-- WARNING: This restores public.find_similar_events_by_id to SECURITY INVOKER,
-- which REINTRODUCES the known anon-block — `anon`/`authenticated` callers will
-- again hit `42501 permission denied` because they have no EXECUTE on the
-- private body. Only use to revert the SECURITY DEFINER fix.
--
-- Restores the exact pre-fix wrapper from 20260601029000_*.sql (signature,
-- body, and grants unchanged from the original).

-- ─── Public wrapper (back to SECURITY INVOKER) ──────────────────────────────
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

-- Restore the original grants.
REVOKE EXECUTE ON FUNCTION public.find_similar_events_by_id(uuid, int, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.find_similar_events_by_id(uuid, int, uuid)
  TO authenticated, anon, service_role;
