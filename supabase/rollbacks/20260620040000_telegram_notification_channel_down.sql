-- Rollback for 20260620040000_telegram_notification_channel.sql
--
-- Drops the two new columns from user_notification_preferences and restores
-- the upsert_notification_preferences RPC to its original 6-parameter form.

BEGIN;

-- ─── Drop new 8-arg overload ─────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.upsert_notification_preferences(
  boolean, boolean, boolean, boolean, boolean, boolean, boolean, text
);

DROP FUNCTION IF EXISTS private.upsert_notification_preferences(
  boolean, boolean, boolean, boolean, boolean, boolean, boolean, text
);

-- ─── Restore original 6-arg private RPC ─────────────────────────────────────

CREATE OR REPLACE FUNCTION private.upsert_notification_preferences(
  p_reminder_email  boolean,
  p_reminder_push   boolean,
  p_change_email    boolean,
  p_change_push     boolean,
  p_digest_email    boolean,
  p_digest_push     boolean
)
RETURNS public.user_notification_preferences
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_user_id uuid;
  v_row     public.user_notification_preferences%ROWTYPE;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'NOTIFICATION_PREFS_AUTH_REQUIRED';
  END IF;

  INSERT INTO public.user_notification_preferences (
    user_id, reminder_email, reminder_push,
    change_email, change_push,
    digest_email, digest_push,
    updated_at
  ) VALUES (
    v_user_id, p_reminder_email, p_reminder_push,
    p_change_email, p_change_push,
    p_digest_email, p_digest_push,
    now()
  )
  ON CONFLICT (user_id) DO UPDATE SET
    reminder_email = EXCLUDED.reminder_email,
    reminder_push  = EXCLUDED.reminder_push,
    change_email   = EXCLUDED.change_email,
    change_push    = EXCLUDED.change_push,
    digest_email   = EXCLUDED.digest_email,
    digest_push    = EXCLUDED.digest_push,
    updated_at     = now()
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

-- ─── Restore original 6-arg public wrapper ──────────────────────────────────

CREATE OR REPLACE FUNCTION public.upsert_notification_preferences(
  p_reminder_email  boolean,
  p_reminder_push   boolean,
  p_change_email    boolean,
  p_change_push     boolean,
  p_digest_email    boolean,
  p_digest_push     boolean
)
RETURNS public.user_notification_preferences
LANGUAGE sql
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT * FROM private.upsert_notification_preferences(
    p_reminder_email, p_reminder_push,
    p_change_email, p_change_push,
    p_digest_email, p_digest_push
  );
$$;

REVOKE ALL ON FUNCTION public.upsert_notification_preferences(boolean, boolean, boolean, boolean, boolean, boolean)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_notification_preferences(boolean, boolean, boolean, boolean, boolean, boolean)
  TO authenticated, service_role;

-- ─── Drop the CHECK constraint + new columns ─────────────────────────────────

ALTER TABLE public.user_notification_preferences
  DROP CONSTRAINT IF EXISTS user_notification_preferences_telegram_chat_id_required_chk;

ALTER TABLE public.user_notification_preferences
  DROP COLUMN IF EXISTS telegram_chat_id;

ALTER TABLE public.user_notification_preferences
  DROP COLUMN IF EXISTS digest_telegram;

COMMIT;
