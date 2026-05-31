-- ============================================================================
-- M003/S01: User notification preferences
-- ============================================================================
-- Per-user toggle table for notification channels. Each user gets one row
-- (upserted on first save). Downstream slices (push, reminders, digest) read
-- these flags to decide which channels to deliver on.
-- ============================================================================

BEGIN;

-- ─── user_notification_preferences table ────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.user_notification_preferences (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  reminder_email  boolean NOT NULL DEFAULT true,
  reminder_push   boolean NOT NULL DEFAULT true,
  change_email    boolean NOT NULL DEFAULT true,
  change_push     boolean NOT NULL DEFAULT true,
  digest_email    boolean NOT NULL DEFAULT true,
  digest_push     boolean NOT NULL DEFAULT false,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.user_notification_preferences IS
  'Per-user notification channel toggles. One row per user, upserted on first '
  'save from the profile page. Downstream notification slices read these flags.';

-- ─── Indexes ────────────────────────────────────────────────────────────────
-- user_id already has UNIQUE constraint which creates an implicit index.

-- ─── RLS ────────────────────────────────────────────────────────────────────

ALTER TABLE public.user_notification_preferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_notification_preferences FORCE ROW LEVEL SECURITY;

CREATE POLICY user_notification_preferences_select_own
  ON public.user_notification_preferences
  FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

CREATE POLICY user_notification_preferences_insert_own
  ON public.user_notification_preferences
  FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid());

CREATE POLICY user_notification_preferences_update_own
  ON public.user_notification_preferences
  FOR UPDATE
  TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- Service role full access (for edge functions / cron)
CREATE POLICY user_notification_preferences_service_all
  ON public.user_notification_preferences
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

GRANT SELECT, INSERT, UPDATE ON public.user_notification_preferences TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_notification_preferences TO service_role;

-- ─── Upsert RPC (private body + public wrapper) ────────────────────────────

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

-- Public wrapper (SECURITY INVOKER, thin SQL delegate)
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

COMMIT;
