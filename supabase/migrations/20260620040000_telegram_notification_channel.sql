-- ============================================================================
-- M003/S02: Telegram notification channel
-- ============================================================================
-- Adds Telegram as a per-user delivery channel for the weekly digest.
-- Two new columns on user_notification_preferences:
--   digest_telegram  — boolean opt-in toggle (default false)
--   telegram_chat_id — the user's Telegram chat ID (DM or group)
--
-- The upsert_notification_preferences RPC enumerates its columns explicitly,
-- so it must be extended to carry the new parameters through.
--
-- Paired rollback:
--   supabase/rollbacks/20260620040000_telegram_notification_channel_down.sql
-- ============================================================================

BEGIN;

-- ─── New columns ────────────────────────────────────────────────────────────

ALTER TABLE public.user_notification_preferences
  ADD COLUMN digest_telegram boolean NOT NULL DEFAULT false;

ALTER TABLE public.user_notification_preferences
  ADD COLUMN telegram_chat_id text;

COMMENT ON COLUMN public.user_notification_preferences.digest_telegram IS
  'When true, send the weekly digest via Telegram Bot API to telegram_chat_id.';

COMMENT ON COLUMN public.user_notification_preferences.telegram_chat_id IS
  'Telegram chat ID (integer as text) for the user''s DM or group. Required when digest_telegram=true.';

-- ─── Replace the 6-arg RPCs with 8-arg overloads ────────────────────────────
-- CREATE OR REPLACE with extra params creates a NEW overload instead of
-- replacing the existing one. Drop the original 6-arg pair first (public
-- wrapper before the private it depends on) so that 6-arg callers resolve
-- unambiguously to the new defaulted signature rather than erroring with
-- "function is not unique".

DROP FUNCTION IF EXISTS public.upsert_notification_preferences(
  boolean, boolean, boolean, boolean, boolean, boolean
);
DROP FUNCTION IF EXISTS private.upsert_notification_preferences(
  boolean, boolean, boolean, boolean, boolean, boolean
);

CREATE OR REPLACE FUNCTION private.upsert_notification_preferences(
  p_reminder_email   boolean,
  p_reminder_push    boolean,
  p_change_email     boolean,
  p_change_push      boolean,
  p_digest_email     boolean,
  p_digest_push      boolean,
  p_digest_telegram  boolean  DEFAULT false,
  p_telegram_chat_id text     DEFAULT NULL
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
    digest_telegram, telegram_chat_id,
    updated_at
  ) VALUES (
    v_user_id, p_reminder_email, p_reminder_push,
    p_change_email, p_change_push,
    p_digest_email, p_digest_push,
    p_digest_telegram, p_telegram_chat_id,
    now()
  )
  ON CONFLICT (user_id) DO UPDATE SET
    reminder_email   = EXCLUDED.reminder_email,
    reminder_push    = EXCLUDED.reminder_push,
    change_email     = EXCLUDED.change_email,
    change_push      = EXCLUDED.change_push,
    digest_email     = EXCLUDED.digest_email,
    digest_push      = EXCLUDED.digest_push,
    digest_telegram  = EXCLUDED.digest_telegram,
    telegram_chat_id = EXCLUDED.telegram_chat_id,
    updated_at       = now()
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

-- ─── Extend public wrapper ────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.upsert_notification_preferences(
  p_reminder_email   boolean,
  p_reminder_push    boolean,
  p_change_email     boolean,
  p_change_push      boolean,
  p_digest_email     boolean,
  p_digest_push      boolean,
  p_digest_telegram  boolean  DEFAULT false,
  p_telegram_chat_id text     DEFAULT NULL
)
RETURNS public.user_notification_preferences
LANGUAGE sql
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT * FROM private.upsert_notification_preferences(
    p_reminder_email, p_reminder_push,
    p_change_email, p_change_push,
    p_digest_email, p_digest_push,
    p_digest_telegram, p_telegram_chat_id
  );
$$;

-- Re-apply grants on the new 8-arg overload (the 6-arg pair was dropped above).
REVOKE ALL ON FUNCTION public.upsert_notification_preferences(
  boolean, boolean, boolean, boolean, boolean, boolean, boolean, text
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.upsert_notification_preferences(
  boolean, boolean, boolean, boolean, boolean, boolean, boolean, text
) TO authenticated, service_role;

COMMIT;
