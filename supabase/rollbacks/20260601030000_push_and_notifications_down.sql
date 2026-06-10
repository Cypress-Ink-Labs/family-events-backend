-- Rollback for 20260601030000_push_and_notifications.sql
-- Reverts (in reverse dependency order):
--   - Drops public/private unregister_push_subscription(uuid)
--   - Drops public/private register_push_subscription(text, text, text, text, text)
--   - Drops public/private mark_all_notifications_read()
--   - Drops public/private mark_notification_read(uuid)
--   - Drops trigger trg_cap_user_notifications on public.user_notifications
--   - Drops private.cap_user_notifications()
--   - Drops table public.user_notifications (DATA LOSS: all in-app notifications
--     permanently deleted)
--   - Drops table public.push_subscriptions (DATA LOSS: all user push tokens
--     permanently deleted)

BEGIN;

-- 1. Drop unregister_push_subscription.
REVOKE ALL ON FUNCTION public.unregister_push_subscription(uuid) FROM authenticated, service_role;
DROP FUNCTION IF EXISTS public.unregister_push_subscription(uuid);
DROP FUNCTION IF EXISTS private.unregister_push_subscription(uuid);

-- 2. Drop register_push_subscription.
REVOKE ALL ON FUNCTION public.register_push_subscription(text, text, text, text, text)
  FROM authenticated, service_role;
DROP FUNCTION IF EXISTS public.register_push_subscription(text, text, text, text, text);
DROP FUNCTION IF EXISTS private.register_push_subscription(text, text, text, text, text);

-- 3. Drop mark_all_notifications_read.
REVOKE ALL ON FUNCTION public.mark_all_notifications_read() FROM authenticated, service_role;
DROP FUNCTION IF EXISTS public.mark_all_notifications_read();
DROP FUNCTION IF EXISTS private.mark_all_notifications_read();

-- 4. Drop mark_notification_read.
REVOKE ALL ON FUNCTION public.mark_notification_read(uuid) FROM authenticated, service_role;
DROP FUNCTION IF EXISTS public.mark_notification_read(uuid);
DROP FUNCTION IF EXISTS private.mark_notification_read(uuid);

-- 5. Drop cap trigger and function.
DROP TRIGGER IF EXISTS trg_cap_user_notifications ON public.user_notifications;
DROP FUNCTION IF EXISTS private.cap_user_notifications();

-- 6. Drop user_notifications table (DATA LOSS: all in-app notification rows deleted).
REVOKE SELECT, UPDATE ON public.user_notifications FROM authenticated;
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.user_notifications FROM service_role;
DROP TABLE IF EXISTS public.user_notifications;

-- 7. Drop push_subscriptions table (DATA LOSS: all user push tokens deleted).
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.push_subscriptions FROM authenticated;
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.push_subscriptions FROM service_role;
DROP TABLE IF EXISTS public.push_subscriptions;

COMMIT;
