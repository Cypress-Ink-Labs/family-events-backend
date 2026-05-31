-- ============================================================================
-- M003/S02: Push subscriptions and user notifications
-- ============================================================================
-- Creates push_subscriptions (web/iOS/Android push tokens) and
-- user_notifications (in-app notification center). Includes RPCs using the
-- private body + public wrapper pattern for all SECURITY DEFINER functions.
-- ============================================================================

BEGIN;

-- ─── push_subscriptions table ───────────────────────────────────────────────
-- Stores push delivery targets per user: web push (endpoint+keys) or
-- mobile FCM tokens (ios/android).

CREATE TABLE IF NOT EXISTS public.push_subscriptions (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  platform    text NOT NULL CHECK (platform IN ('web', 'ios', 'android')),
  endpoint    text,         -- web push subscription URL
  token       text,         -- FCM token for ios/android
  p256dh      text,         -- web push key
  auth_key    text,         -- web push auth secret
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),

  -- Web subscriptions are unique by endpoint
  CONSTRAINT push_subscriptions_web_unique
    UNIQUE NULLS NOT DISTINCT (user_id, endpoint),
  -- Mobile subscriptions are unique by token
  CONSTRAINT push_subscriptions_mobile_unique
    UNIQUE NULLS NOT DISTINCT (user_id, token),
  -- Web must have endpoint+keys; mobile must have token
  CONSTRAINT push_subscriptions_platform_fields CHECK (
    CASE
      WHEN platform = 'web' THEN endpoint IS NOT NULL AND p256dh IS NOT NULL AND auth_key IS NOT NULL
      ELSE token IS NOT NULL
    END
  )
);

COMMENT ON TABLE public.push_subscriptions IS
  'Push delivery targets per user. Web push uses endpoint/p256dh/auth_key; '
  'mobile (ios/android) uses FCM token. Pruned on delivery failure (410/404).';

CREATE INDEX IF NOT EXISTS push_subscriptions_user_id_idx
  ON public.push_subscriptions (user_id);

-- ─── push_subscriptions RLS ─────────────────────────────────────────────────

ALTER TABLE public.push_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.push_subscriptions FORCE ROW LEVEL SECURITY;

CREATE POLICY push_subscriptions_select_own
  ON public.push_subscriptions FOR SELECT TO authenticated
  USING (user_id = auth.uid());

CREATE POLICY push_subscriptions_insert_own
  ON public.push_subscriptions FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

CREATE POLICY push_subscriptions_update_own
  ON public.push_subscriptions FOR UPDATE TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

CREATE POLICY push_subscriptions_delete_own
  ON public.push_subscriptions FOR DELETE TO authenticated
  USING (user_id = auth.uid());

CREATE POLICY push_subscriptions_service_all
  ON public.push_subscriptions FOR ALL TO service_role
  USING (true)
  WITH CHECK (true);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.push_subscriptions TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.push_subscriptions TO service_role;

-- ─── user_notifications table ───────────────────────────────────────────────
-- In-app notification center. Capped at 100 per user via trigger.

CREATE TABLE IF NOT EXISTS public.user_notifications (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  type        text NOT NULL CHECK (type IN ('reminder', 'change', 'digest', 'system')),
  title       text NOT NULL,
  body        text NOT NULL,
  event_id    uuid REFERENCES public.events(id) ON DELETE SET NULL,
  read_at     timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.user_notifications IS
  'In-app notification center items. Capped at 100 per user by trigger. '
  'Supports linking to events and read/unread state.';

CREATE INDEX IF NOT EXISTS user_notifications_user_created_idx
  ON public.user_notifications (user_id, created_at DESC);

-- ─── user_notifications RLS ─────────────────────────────────────────────────

ALTER TABLE public.user_notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_notifications FORCE ROW LEVEL SECURITY;

CREATE POLICY user_notifications_select_own
  ON public.user_notifications FOR SELECT TO authenticated
  USING (user_id = auth.uid());

CREATE POLICY user_notifications_update_own
  ON public.user_notifications FOR UPDATE TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

CREATE POLICY user_notifications_service_all
  ON public.user_notifications FOR ALL TO service_role
  USING (true)
  WITH CHECK (true);

GRANT SELECT, UPDATE ON public.user_notifications TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_notifications TO service_role;

-- ─── Cap trigger: keep at most 100 notifications per user ───────────────────

CREATE OR REPLACE FUNCTION private.cap_user_notifications()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $$
BEGIN
  DELETE FROM public.user_notifications
  WHERE id IN (
    SELECT id FROM public.user_notifications
    WHERE user_id = NEW.user_id
    ORDER BY created_at DESC
    OFFSET 100
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_cap_user_notifications
  AFTER INSERT ON public.user_notifications
  FOR EACH ROW
  EXECUTE FUNCTION private.cap_user_notifications();

-- ─── RPCs: mark_notification_read ───────────────────────────────────────────

CREATE OR REPLACE FUNCTION private.mark_notification_read(p_notification_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'NOTIFICATION_AUTH_REQUIRED';
  END IF;

  UPDATE public.user_notifications
  SET read_at = now()
  WHERE id = p_notification_id
    AND user_id = v_user_id
    AND read_at IS NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_notification_read(p_notification_id uuid)
RETURNS void
LANGUAGE sql
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT private.mark_notification_read(p_notification_id);
$$;

REVOKE ALL ON FUNCTION public.mark_notification_read(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_notification_read(uuid)
  TO authenticated, service_role;

-- ─── RPCs: mark_all_notifications_read ──────────────────────────────────────

CREATE OR REPLACE FUNCTION private.mark_all_notifications_read()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'NOTIFICATION_AUTH_REQUIRED';
  END IF;

  UPDATE public.user_notifications
  SET read_at = now()
  WHERE user_id = v_user_id
    AND read_at IS NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_all_notifications_read()
RETURNS void
LANGUAGE sql
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT private.mark_all_notifications_read();
$$;

REVOKE ALL ON FUNCTION public.mark_all_notifications_read() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_all_notifications_read()
  TO authenticated, service_role;

-- ─── RPCs: register_push_subscription ───────────────────────────────────────

CREATE OR REPLACE FUNCTION private.register_push_subscription(
  p_platform  text,
  p_endpoint  text DEFAULT NULL,
  p_token     text DEFAULT NULL,
  p_p256dh    text DEFAULT NULL,
  p_auth_key  text DEFAULT NULL
)
RETURNS public.push_subscriptions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_user_id uuid;
  v_row     public.push_subscriptions%ROWTYPE;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'PUSH_SUB_AUTH_REQUIRED';
  END IF;

  IF p_platform NOT IN ('web', 'ios', 'android') THEN
    RAISE EXCEPTION 'PUSH_SUB_INVALID_PLATFORM';
  END IF;

  IF p_platform = 'web' THEN
    IF p_endpoint IS NULL OR p_p256dh IS NULL OR p_auth_key IS NULL THEN
      RAISE EXCEPTION 'PUSH_SUB_WEB_FIELDS_REQUIRED';
    END IF;

    INSERT INTO public.push_subscriptions (user_id, platform, endpoint, p256dh, auth_key, updated_at)
    VALUES (v_user_id, p_platform, p_endpoint, p_p256dh, p_auth_key, now())
    ON CONFLICT (user_id, endpoint)
    DO UPDATE SET p256dh = EXCLUDED.p256dh, auth_key = EXCLUDED.auth_key, updated_at = now()
    RETURNING * INTO v_row;
  ELSE
    IF p_token IS NULL THEN
      RAISE EXCEPTION 'PUSH_SUB_TOKEN_REQUIRED';
    END IF;

    INSERT INTO public.push_subscriptions (user_id, platform, token, updated_at)
    VALUES (v_user_id, p_platform, p_token, now())
    ON CONFLICT (user_id, token)
    DO UPDATE SET platform = EXCLUDED.platform, updated_at = now()
    RETURNING * INTO v_row;
  END IF;

  RETURN v_row;
END;
$$;

CREATE OR REPLACE FUNCTION public.register_push_subscription(
  p_platform  text,
  p_endpoint  text DEFAULT NULL,
  p_token     text DEFAULT NULL,
  p_p256dh    text DEFAULT NULL,
  p_auth_key  text DEFAULT NULL
)
RETURNS public.push_subscriptions
LANGUAGE sql
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT * FROM private.register_push_subscription(
    p_platform, p_endpoint, p_token, p_p256dh, p_auth_key
  );
$$;

REVOKE ALL ON FUNCTION public.register_push_subscription(text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_push_subscription(text, text, text, text, text)
  TO authenticated, service_role;

-- ─── RPCs: unregister_push_subscription ─────────────────────────────────────

CREATE OR REPLACE FUNCTION private.unregister_push_subscription(
  p_subscription_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'PUSH_SUB_AUTH_REQUIRED';
  END IF;

  DELETE FROM public.push_subscriptions
  WHERE id = p_subscription_id
    AND user_id = v_user_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.unregister_push_subscription(
  p_subscription_id uuid
)
RETURNS void
LANGUAGE sql
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT private.unregister_push_subscription(p_subscription_id);
$$;

REVOKE ALL ON FUNCTION public.unregister_push_subscription(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.unregister_push_subscription(uuid)
  TO authenticated, service_role;

COMMIT;
