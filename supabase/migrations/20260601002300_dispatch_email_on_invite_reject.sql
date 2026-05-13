-- Send a notification email to the requester when their invite request is
-- rejected. Mirrors the dispatch pattern in admin_approve_invite_request:
-- fire-and-forget through pg_net, swallowed via EXCEPTION block so a notify
-- outage never bubbles back to the admin clicking "Reject".
--
-- The rejection email is intentionally generic — it carries no admin_notes,
-- no retry CTA, and no schema-level reason. admin_notes remains internal.
-- The email body lives in supabase/functions/notify-email (kind = 'request_rejected').

BEGIN;

CREATE OR REPLACE FUNCTION private.admin_reject_invite_request(p_request_id uuid, p_notes text DEFAULT NULL::text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller uuid;
  v_notes  text;
  v_email  text;
  v_rows   int;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  v_caller := auth.uid();
  v_notes := nullif(btrim(coalesce(p_notes, '')), '');
  IF v_notes IS NOT NULL AND length(v_notes) > 1000 THEN
    v_notes := substring(v_notes FROM 1 FOR 1000);
  END IF;

  -- Capture the requester email up-front so the dispatch can fire even though
  -- the row UPDATE flips its status; the column value itself doesn't change.
  SELECT r.email INTO v_email
  FROM public.invite_requests r
  WHERE r.id = p_request_id AND r.status = 'pending'
  FOR UPDATE;

  IF v_email IS NULL THEN
    RETURN false;
  END IF;

  UPDATE public.invite_requests
  SET
    status      = 'rejected',
    admin_notes = v_notes,
    reviewed_at = now(),
    reviewed_by = v_caller
  WHERE id = p_request_id;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RETURN false;
  END IF;

  -- Notify the requester. Async + swallowed so an email outage never blocks
  -- the admin's reject action — the DB transition already happened above.
  BEGIN
    PERFORM private.dispatch_email_notification(jsonb_build_object(
      'kind',  'request_rejected',
      'email', v_email
    ));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Failed to dispatch rejected invite email: %', SQLERRM;
  END;

  RETURN true;
END;
$$;

REVOKE EXECUTE ON FUNCTION private.admin_reject_invite_request(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.admin_reject_invite_request(uuid, text) TO authenticated, service_role;

COMMIT;
