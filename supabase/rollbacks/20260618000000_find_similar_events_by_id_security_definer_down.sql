-- Rollback for 20260618000000_find_similar_events_by_id_security_definer.sql
--
-- WARNING: This restores public.find_similar_events_by_id to SECURITY INVOKER,
-- which REINTRODUCES the known anon-block — `anon`/`authenticated` callers will
-- again hit `42501 permission denied` because they have no EXECUTE on the
-- private body. Only use to revert the SECURITY DEFINER fix.
--
-- Restores the exact pre-fix state from 20260601029000_*.sql: the public wrapper
-- (SECURITY INVOKER + original grants) AND the private body (without the
-- source-published gate this migration added).

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

-- ─── Private body (restore original, WITHOUT the source-published gate) ─────
-- Reverts the defense-in-depth source gate added by the forward migration back
-- to the original 20260601029000 body (source embedding looked up with no status
-- check). Safe in the rolled-back state because the wrapper is INVOKER again, so
-- anon/authenticated cannot reach this path.
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
  SELECT ee.embedding INTO v_embedding
  FROM public.event_embeddings ee
  WHERE ee.event_id = p_event_id;

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
