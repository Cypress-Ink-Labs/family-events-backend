-- Phase 8: anon-callable invite request flow
-- ----------------------------------------------------------------
-- Adds a "request an invite code" pipeline parallel to the
-- admin-generated-code flow. Users without an invite can submit their
-- email + optional message; admins review and approve in one click,
-- which generates a fresh code and links it to the request.
--
-- Threat model: anon endpoint, so rate-limiting by email_hash mirrors
-- redeem_invite_for_email (stores sha256(lower(email)) rather than the
-- raw email so the enumeration-attractive attempts table can't leak who
-- has tried to request).

BEGIN;

-- =============================================
-- 1. Status enum for the request lifecycle
-- =============================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'invite_request_status') THEN
    CREATE TYPE public.invite_request_status AS ENUM (
      'pending',
      'approved',
      'rejected'
    );
  END IF;
END $$;

-- =============================================
-- 2. invite_requests table
-- =============================================
CREATE TABLE IF NOT EXISTS public.invite_requests (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email         text NOT NULL,
  message       text,
  status        public.invite_request_status NOT NULL DEFAULT 'pending',
  -- When approved, links to the invite_codes row generated for this request.
  invite_code_id uuid REFERENCES public.invite_codes(id) ON DELETE SET NULL,
  admin_notes   text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  reviewed_at   timestamptz,
  reviewed_by   uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  CONSTRAINT invite_requests_message_len_chk CHECK (message IS NULL OR length(message) <= 500),
  CONSTRAINT invite_requests_email_len_chk CHECK (length(email) BETWEEN 3 AND 320),
  CONSTRAINT invite_requests_admin_notes_len_chk
    CHECK (admin_notes IS NULL OR length(admin_notes) <= 1000)
);

-- Allow only ONE pending request per email at a time. Approved/rejected
-- rows can accumulate as audit; re-requesting after rejection creates a
-- fresh pending row because the partial index only constrains 'pending'.
CREATE UNIQUE INDEX IF NOT EXISTS invite_requests_email_pending_uniq
  ON public.invite_requests (lower(email))
  WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS invite_requests_status_created_idx
  ON public.invite_requests (status, created_at DESC);

ALTER TABLE public.invite_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invite_requests FORCE ROW LEVEL SECURITY;

-- Admins can read everything; no direct INSERT/UPDATE/DELETE from clients
-- (all writes go through SECURITY DEFINER RPCs).
DROP POLICY IF EXISTS "Admins can read invite requests" ON public.invite_requests;
CREATE POLICY "Admins can read invite requests"
  ON public.invite_requests FOR SELECT TO authenticated
  USING (private.is_admin());

COMMENT ON TABLE public.invite_requests IS
  'Anon-submitted invite requests. Admin approval generates an invite_codes
   row and links it via invite_code_id, then the admin shares the plaintext
   out-of-band.';

-- =============================================
-- 3. Rate-limit table (email_hash, not raw email)
-- =============================================
CREATE TABLE IF NOT EXISTS public.invite_request_attempts (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email_hash   text NOT NULL,
  attempted_at timestamptz NOT NULL DEFAULT now(),
  succeeded    boolean NOT NULL
);
ALTER TABLE public.invite_request_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invite_request_attempts FORCE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS invite_request_attempts_email_hash_idx
  ON public.invite_request_attempts (email_hash, attempted_at DESC);

DROP POLICY IF EXISTS "Admins can read invite request attempts" ON public.invite_request_attempts;
CREATE POLICY "Admins can read invite request attempts"
  ON public.invite_request_attempts FOR SELECT TO authenticated
  USING (private.is_admin());

-- =============================================
-- 4. private.is_invite_request_rate_limited
-- 3 attempts in the last 10 minutes per email_hash trips the limit.
-- Lower bar than redemption because request submits are cheaper to abuse
-- but also cheaper to absorb (no capacity burn).
-- =============================================
CREATE OR REPLACE FUNCTION private.is_invite_request_rate_limited(p_email_hash text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT count(*) >= 3
  FROM public.invite_request_attempts
  WHERE email_hash = p_email_hash
    AND attempted_at > now() - interval '10 minutes';
$$;

REVOKE ALL ON FUNCTION private.is_invite_request_rate_limited(text) FROM PUBLIC;

-- =============================================
-- 5. public.request_invite(email, message) — anon-callable
-- Idempotent: re-submitting the same email while a pending row exists
-- returns true without creating a duplicate row.
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
BEGIN
  v_canonical_email := lower(btrim(coalesce(p_email, '')));
  IF v_canonical_email = '' OR position('@' IN v_canonical_email) = 0 THEN
    RETURN false;
  END IF;

  v_email_hash := encode(extensions.digest(v_canonical_email, 'sha256'), 'hex');

  IF private.is_invite_request_rate_limited(v_email_hash) THEN
    RETURN false;
  END IF;

  -- Trim and cap optional message at 500 chars; empty-after-trim → null.
  v_trimmed_message := nullif(btrim(coalesce(p_message, '')), '');
  IF v_trimmed_message IS NOT NULL AND length(v_trimmed_message) > 500 THEN
    v_trimmed_message := substring(v_trimmed_message FROM 1 FOR 500);
  END IF;

  -- Idempotent: if a pending row already exists for this email, refresh
  -- the message (in case they're providing more context) and succeed.
  -- The partial unique index on (lower(email)) WHERE status='pending'
  -- enforces this at the DB level.
  IF EXISTS (
    SELECT 1 FROM public.invite_requests
    WHERE lower(email) = v_canonical_email AND status = 'pending'
  ) THEN
    UPDATE public.invite_requests
    SET message = coalesce(v_trimmed_message, message)
    WHERE lower(email) = v_canonical_email AND status = 'pending';
  ELSE
    INSERT INTO public.invite_requests (email, message)
    VALUES (v_canonical_email, v_trimmed_message);
  END IF;

  INSERT INTO public.invite_request_attempts (email_hash, succeeded)
    VALUES (v_email_hash, true);

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.request_invite(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_invite(text, text) TO anon, authenticated;

-- =============================================
-- 6. public.admin_approve_invite_request(p_request_id)
-- One-click: generate a fresh invite code (max_uses=1, no expiry by default),
-- link it to the request, mark approved, and return the plaintext so the
-- admin UI can surface it once via the existing reveal panel.
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

  -- Lock the request row to prevent two admins approving the same request
  -- concurrently (which would generate two codes against the same request).
  -- The table alias `r` keeps the column reference unambiguous against the
  -- RETURNS TABLE's implicit `email` local variable.
  SELECT r.email INTO v_email
  FROM public.invite_requests r
  WHERE r.id = p_request_id AND r.status = 'pending'
  FOR UPDATE;

  IF v_email IS NULL THEN
    RAISE EXCEPTION 'request not found or already reviewed' USING ERRCODE = 'P0002';
  END IF;

  -- Generate code (same alphabet + length as admin_create_invite_code).
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

-- =============================================
-- 7. public.admin_reject_invite_request(p_request_id, p_notes)
-- =============================================
CREATE OR REPLACE FUNCTION public.admin_reject_invite_request(
  p_request_id uuid,
  p_notes      text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller uuid;
  v_notes  text;
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

  UPDATE public.invite_requests
  SET
    status      = 'rejected',
    admin_notes = v_notes,
    reviewed_at = now(),
    reviewed_by = v_caller
  WHERE id = p_request_id AND status = 'pending';

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows > 0;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_reject_invite_request(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_reject_invite_request(uuid, text) TO authenticated;

-- =============================================
-- 8. Daily prune of rate-limit attempts older than 30 days
-- =============================================
DO $$
BEGIN
  BEGIN
    PERFORM cron.unschedule('invite-request-attempts-prune-daily');
  EXCEPTION
    WHEN undefined_object THEN NULL;
    WHEN OTHERS THEN
      RAISE WARNING 'Unexpected error unscheduling invite-request-attempts-prune-daily: %', SQLERRM;
  END;
  PERFORM cron.schedule(
    'invite-request-attempts-prune-daily',
    '45 3 * * *',
    $sql$
      DELETE FROM public.invite_request_attempts
      WHERE attempted_at < now() - interval '30 days';
    $sql$
  );
END $$;

COMMIT;
