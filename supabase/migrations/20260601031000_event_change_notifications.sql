-- ============================================================================
-- M003/S03: Event change notifications
-- ============================================================================
-- Creates a notification_queue table for debounced event change notifications.
-- A trigger on events detects meaningful changes (time, venue, cancellation)
-- and inserts into the queue. A separate cron (process-notification-queue)
-- reads the queue after the debounce window and dispatches to subscribers.
-- ============================================================================

BEGIN;

-- ─── notification_queue table ───────────────────────────────────────────────
-- Debounce buffer for event change notifications. Each row represents one
-- pending change notification for a user+event pair. The 1-hour dedup window
-- prevents notification storms during bulk re-scrape operations.

CREATE TABLE IF NOT EXISTS public.notification_queue (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  event_id     uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  change_type  text NOT NULL CHECK (change_type IN (
    'time_changed', 'venue_changed', 'cancelled', 'status_changed'
  )),
  change_detail jsonb DEFAULT '{}'::jsonb,
  processed    boolean NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz
);

COMMENT ON TABLE public.notification_queue IS
  'Debounce buffer for event change notifications. Entries are processed by '
  'the process-notification-queue cron after the 1-hour dedup window. '
  'Dedup constraint prevents duplicate notifications during bulk re-scrape.';

-- Dedup: one notification per user+event+change_type per 1-hour window.
-- We use a unique index on (user_id, event_id, change_type) filtered to
-- unprocessed entries. When a duplicate arrives within the window, the
-- trigger uses ON CONFLICT to update the detail instead of inserting.
CREATE UNIQUE INDEX IF NOT EXISTS notification_queue_dedup_idx
  ON public.notification_queue (user_id, event_id, change_type)
  WHERE processed = false;

CREATE INDEX IF NOT EXISTS notification_queue_pending_idx
  ON public.notification_queue (processed, created_at)
  WHERE processed = false;

CREATE INDEX IF NOT EXISTS notification_queue_user_id_idx
  ON public.notification_queue (user_id);

-- ─── notification_queue RLS ─────────────────────────────────────────────────

ALTER TABLE public.notification_queue ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notification_queue FORCE ROW LEVEL SECURITY;

-- Users don't read this table directly — it's internal. Service role only.
CREATE POLICY notification_queue_service_all
  ON public.notification_queue FOR ALL TO service_role
  USING (true)
  WITH CHECK (true);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.notification_queue TO service_role;

-- ─── Trigger function: detect event changes ─────────────────────────────────
-- Fires on UPDATE of the events table. Detects meaningful changes and queues
-- notifications to all users who have favorited (saved) the event.

CREATE OR REPLACE FUNCTION private.notify_event_changes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_change_type  text;
  v_change_detail jsonb;
  v_time_changed boolean;
  v_venue_changed boolean;
  v_cancelled boolean;
BEGIN
  -- Only process published events (or events going to archived/rejected)
  IF OLD.status != 'published' AND NEW.status NOT IN ('archived', 'rejected') THEN
    RETURN NEW;
  END IF;

  v_time_changed := (
    OLD.start_datetime IS DISTINCT FROM NEW.start_datetime
    OR OLD.end_datetime IS DISTINCT FROM NEW.end_datetime
  );

  v_venue_changed := (
    OLD.venue_name IS DISTINCT FROM NEW.venue_name
    OR OLD.address IS DISTINCT FROM NEW.address
  );

  v_cancelled := (
    OLD.status = 'published'
    AND NEW.status IN ('archived', 'rejected')
  );

  -- Priority: cancellation > time > venue
  IF v_cancelled THEN
    v_change_type := 'cancelled';
    v_change_detail := jsonb_build_object(
      'old_status', OLD.status,
      'new_status', NEW.status
    );
  ELSIF v_time_changed THEN
    v_change_type := 'time_changed';
    v_change_detail := jsonb_build_object(
      'old_start', OLD.start_datetime,
      'new_start', NEW.start_datetime,
      'old_end', OLD.end_datetime,
      'new_end', NEW.end_datetime
    );
  ELSIF v_venue_changed THEN
    v_change_type := 'venue_changed';
    v_change_detail := jsonb_build_object(
      'old_venue', OLD.venue_name,
      'new_venue', NEW.venue_name,
      'old_address', OLD.address,
      'new_address', NEW.address
    );
  ELSE
    -- No meaningful change
    RETURN NEW;
  END IF;

  -- Queue notifications for all users who favorited this event.
  -- ON CONFLICT updates the detail if a duplicate exists in the dedup window.
  INSERT INTO public.notification_queue (user_id, event_id, change_type, change_detail)
  SELECT f.user_id, NEW.id, v_change_type, v_change_detail
  FROM public.favorites f
  WHERE f.event_id = NEW.id
  ON CONFLICT (user_id, event_id, change_type) WHERE processed = false
  DO UPDATE SET
    change_detail = EXCLUDED.change_detail,
    created_at = now();

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_notify_event_changes
  AFTER UPDATE ON public.events
  FOR EACH ROW
  EXECUTE FUNCTION private.notify_event_changes();

COMMIT;
