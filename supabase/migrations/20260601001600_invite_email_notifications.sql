-- Wire invite-request RPCs to fire-and-forget email notifications.
-- ----------------------------------------------------------------
-- Adds a private helper that posts to /functions/v1/notify-email via
-- pg_net.http_post, then updates request_invite + admin_approve_invite_request
-- to call it. Email failures NEVER block the user-facing flow (the network
-- call is asynchronous and pg_net + the edge function both swallow errors).

BEGIN;

-- =============================================
-- 1. Helper: post a notification payload to notify-email
-- Reuses the same vault.secrets / GUC fallback pattern as
-- invoke_scrape_source and invoke_process_tag_queue.
-- =============================================
CREATE OR REPLACE FUNCTION private.dispatch_email_notification(p_payload jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_supabase_url  text;
  v_service_role  text;
BEGIN
  v_supabase_url := current_setting('app.settings.supabase_url', true);

  SELECT decrypted_secret INTO v_service_role
  FROM vault.decrypted_secrets
  WHERE name = 'scrape_service_role_key'
  LIMIT 1;

  IF v_service_role IS NULL THEN
    v_service_role := current_setting('app.settings.service_role_key', true);
  END IF;

  IF v_supabase_url IS NULL OR v_service_role IS NULL THEN
    -- Match the no-op fallback used by invoke_scrape_source so a dev/staging
    -- environment without secrets keeps working.
    RAISE NOTICE 'Skipping email notification: missing supabase_url or service_role_key';
    RETURN;
  END IF;

  -- pg_net is async; this call returns immediately and the actual HTTP
  -- request runs in the background. Email failures never block the RPC.
  PERFORM net.http_post(
    url     := v_supabase_url || '/functions/v1/notify-email',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_service_role
    ),
    body    := p_payload
  );
END;
$$;

REVOKE ALL ON FUNCTION private.dispatch_email_notification(jsonb) FROM PUBLIC;

-- =============================================
-- 2. request_invite — fire 'admin_request' notification after a successful submit
-- =============================================
CREATE OR REPLACE FUNCTION public.request_invite(p_email text, p_message text DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_canonical_email text;
  v_email_hash      text;
  v_trimmed_message text;
  v_request_id      uuid;
BEGIN
  v_canonical_email := lower(btrim(coalesce(p_email, '')));
  IF v_canonical_email = '' OR position('@' IN v_canonical_email) = 0 THEN
    RETURN false;
  END IF;

  v_email_hash := encode(extensions.digest(v_canonical_email, 'sha256'), 'hex');

  IF private.is_invite_request_rate_limited(v_email_hash) THEN
    RETURN false;
  END IF;

  v_trimmed_message := nullif(btrim(coalesce(p_message, '')), '');
  IF v_trimmed_message IS NOT NULL AND length(v_trimmed_message) > 500 THEN
    v_trimmed_message := substring(v_trimmed_message FROM 1 FOR 500);
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.invite_requests
    WHERE lower(email) = v_canonical_email AND status = 'pending'
  ) THEN
    UPDATE public.invite_requests
    SET message = coalesce(v_trimmed_message, message)
    WHERE lower(email) = v_canonical_email AND status = 'pending'
    RETURNING id INTO v_request_id;
  ELSE
    INSERT INTO public.invite_requests (email, message)
    VALUES (v_canonical_email, v_trimmed_message)
    RETURNING id INTO v_request_id;
  END IF;

  INSERT INTO public.invite_request_attempts (email_hash, succeeded)
    VALUES (v_email_hash, true);

  -- Notify the admin async. Wrapped in EXCEPTION so a vault/secret hiccup
  -- never bubbles up to the anon caller — the request is already persisted.
  BEGIN
    PERFORM private.dispatch_email_notification(jsonb_build_object(
      'kind',       'admin_request',
      'request_id', v_request_id,
      'email',      v_canonical_email,
      'message',    v_trimmed_message
    ));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Failed to dispatch admin invite-request email: %', SQLERRM;
  END;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.request_invite(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_invite(text, text) TO anon, authenticated;

-- =============================================
-- 3. admin_approve_invite_request — fire 'request_approved' to the requester
-- =============================================
CREATE OR REPLACE FUNCTION public.admin_approve_invite_request(p_request_id uuid)
RETURNS TABLE (
  request_id uuid,
  code       text,
  invite_code_id uuid,
  email      text,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_email       text;
  v_code        text;
  v_code_hash   text;
  v_id          uuid;
  v_caller      uuid;
  v_alphabet    constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_length      constant int  := 24;
  i             int;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  v_caller := auth.uid();

  -- Table alias keeps the column reference unambiguous against the
  -- RETURNS TABLE's implicit `email` local variable.
  SELECT r.email INTO v_email
  FROM public.invite_requests r
  WHERE r.id = p_request_id AND r.status = 'pending'
  FOR UPDATE;

  IF v_email IS NULL THEN
    RAISE EXCEPTION 'request not found or already reviewed' USING ERRCODE = 'P0002';
  END IF;

  v_code := '';
  FOR i IN 1..v_length LOOP
    v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
  END LOOP;

  v_code_hash := private.hash_invite_code(v_code);

  INSERT INTO public.invite_codes (code_hash, max_uses, expires_at, notes, created_by, created_at)
  VALUES (
    v_code_hash, 1, NULL,
    'Approved invite request: ' || v_email,
    v_caller, now()
  )
  RETURNING public.invite_codes.id INTO v_id;

  UPDATE public.invite_requests
  SET
    status         = 'approved',
    invite_code_id = v_id,
    reviewed_at    = now(),
    reviewed_by    = v_caller
  WHERE id = p_request_id;

  -- Email the requester their code. Async + swallowed so an email outage
  -- never blocks the admin's approve action.
  BEGIN
    PERFORM private.dispatch_email_notification(jsonb_build_object(
      'kind',  'request_approved',
      'email', v_email,
      'code',  v_code
    ));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Failed to dispatch approved invite email: %', SQLERRM;
  END;

  RETURN QUERY
  SELECT
    p_request_id,
    v_code,
    v_id,
    v_email,
    now()::timestamptz;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_approve_invite_request(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_approve_invite_request(uuid) TO authenticated;

COMMIT;
