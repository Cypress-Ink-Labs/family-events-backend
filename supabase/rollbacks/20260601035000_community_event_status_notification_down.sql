-- Rollback for 20260601035000_community_event_status_notification.sql
-- Reverts:
--   - DROP TRIGGER trg_notify_community_event_status ON public.events
--   - DROP FUNCTION private.notify_community_event_status()

BEGIN;

-- 1. Drop trigger first (depends on the function).
DROP TRIGGER IF EXISTS trg_notify_community_event_status ON public.events;

-- 2. Drop the trigger function.
DROP FUNCTION IF EXISTS private.notify_community_event_status();

COMMIT;
