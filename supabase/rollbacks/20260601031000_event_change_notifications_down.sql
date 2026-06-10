-- Rollback for 20260601031000_event_change_notifications.sql
-- Reverts (in reverse dependency order):
--   - Drops trigger trg_notify_event_changes on public.events
--   - Drops private.notify_event_changes()
--   - Drops RLS policy notification_queue_service_all on public.notification_queue
--   - Drops indexes: notification_queue_user_id_idx, notification_queue_pending_idx,
--     notification_queue_dedup_idx
--   - Drops table public.notification_queue (DATA LOSS: all pending and processed
--     change notification queue entries permanently deleted)

BEGIN;

-- 1. Drop trigger and trigger function.
DROP TRIGGER IF EXISTS trg_notify_event_changes ON public.events;
DROP FUNCTION IF EXISTS private.notify_event_changes();

-- 2. Drop RLS policy.
DROP POLICY IF EXISTS notification_queue_service_all ON public.notification_queue;

-- 3. Drop indexes (implicitly dropped with table, but explicit for clarity).
DROP INDEX IF EXISTS public.notification_queue_user_id_idx;
DROP INDEX IF EXISTS public.notification_queue_pending_idx;
DROP INDEX IF EXISTS public.notification_queue_dedup_idx;

-- 4. Drop table (DATA LOSS: all notification queue rows permanently deleted).
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.notification_queue FROM service_role;
DROP TABLE IF EXISTS public.notification_queue;

COMMIT;
