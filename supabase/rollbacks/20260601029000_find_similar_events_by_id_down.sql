-- Rollback for 20260601029000_find_similar_events_by_id.sql
-- Reverts:
--   - Drops GRANT on public.find_similar_events_by_id(uuid, int, uuid)
--   - Drops public.find_similar_events_by_id(uuid, int, uuid)
--   - Drops GRANT on private.find_similar_events_by_id(uuid, int, uuid)
--   - Drops private.find_similar_events_by_id(uuid, int, uuid)

BEGIN;

-- 1. Drop public wrapper.
REVOKE EXECUTE ON FUNCTION public.find_similar_events_by_id(uuid, int, uuid)
  FROM authenticated, anon, service_role;

DROP FUNCTION IF EXISTS public.find_similar_events_by_id(uuid, int, uuid);

-- 2. Drop private body.
REVOKE EXECUTE ON FUNCTION private.find_similar_events_by_id(uuid, int, uuid)
  FROM service_role;

DROP FUNCTION IF EXISTS private.find_similar_events_by_id(uuid, int, uuid);

COMMIT;
