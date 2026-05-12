-- Phase 3e: invite-code hard cutover
-- ----------------------------------------------------------------
-- Move invite_codes from plaintext-PK to hashed storage. This is a HARD
-- cutover (per the audit decision) — all existing unredeemed codes are
-- invalidated. Operators must regenerate new codes through the new
-- admin_create_invite_code RPC and re-share them with invitees.
--
-- Threat model: previously, anyone with DB read access could enumerate
-- live invite codes and use them. Now the DB stores only sha256 hashes;
-- a leaked dump is useless for redemption. New plaintext codes are only
-- visible to the admin at creation time (returned once by the RPC).

BEGIN;

-- =============================================
-- 1. Add invite_redemption_attempts (rate-limit table).
-- We store sha256(email) instead of raw email so this enumeration-
-- attractive table doesn't leak every email that ever tried to redeem.
-- =============================================
CREATE TABLE IF NOT EXISTS public.invite_redemption_attempts (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email_hash   text NOT NULL,
  attempted_at timestamptz NOT NULL DEFAULT now(),
  succeeded    boolean NOT NULL
);
ALTER TABLE public.invite_redemption_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invite_redemption_attempts FORCE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS invite_redemption_attempts_email_hash_idx
  ON public.invite_redemption_attempts (email_hash, attempted_at DESC);

-- Admins can SELECT for audit; no direct INSERT/UPDATE/DELETE.
-- Functions run SECURITY DEFINER and bypass RLS for writes.
DROP POLICY IF EXISTS "Admins can read invite redemption attempts" ON public.invite_redemption_attempts;
CREATE POLICY "Admins can read invite redemption attempts"
  ON public.invite_redemption_attempts FOR SELECT TO authenticated
  USING (private.is_admin());

-- =============================================
-- 2. Add code_hash column to invite_codes and backfill from existing code.
-- =============================================
ALTER TABLE public.invite_codes
  ADD COLUMN IF NOT EXISTS code_hash text;

UPDATE public.invite_codes
SET code_hash = encode(extensions.digest(code, 'sha256'), 'hex')
WHERE code_hash IS NULL;

-- =============================================
-- 3. Invalidate every unredeemed code as part of the hard cutover.
-- Operators must regenerate via admin_create_invite_code after deploy.
-- =============================================
UPDATE public.invite_codes
SET used_count = max_uses
WHERE used_count < max_uses;

-- Also expire any unclaimed pending_invite_claims so /sign-up doesn't think
-- a freshly-deployed prod still has live claims.
UPDATE public.pending_invite_claims
SET expires_at = now() - interval '1 second'
WHERE claimed_by IS NULL AND expires_at > now();

-- =============================================
-- 4. Add surrogate uuid id, drop the FK on pending_invite_claims.invite_code,
-- then swap PRIMARY KEY from code -> id, finally drop the plaintext column.
-- pending_invite_claims.invite_code becomes a plain text audit field
-- (no FK). Those rows live ~2h, so loss of referential integrity is fine.
-- =============================================
ALTER TABLE public.invite_codes
  ADD COLUMN IF NOT EXISTS id uuid NOT NULL DEFAULT gen_random_uuid();

ALTER TABLE public.pending_invite_claims
  DROP CONSTRAINT IF EXISTS pending_invite_claims_invite_code_fkey;

ALTER TABLE public.invite_codes DROP CONSTRAINT IF EXISTS invite_codes_pkey;
ALTER TABLE public.invite_codes ADD PRIMARY KEY (id);

ALTER TABLE public.invite_codes ALTER COLUMN code_hash SET NOT NULL;
ALTER TABLE public.invite_codes
  ADD CONSTRAINT invite_codes_code_hash_uniq UNIQUE (code_hash);
ALTER TABLE public.invite_codes
  ADD CONSTRAINT invite_codes_code_hash_len_chk
    CHECK (length(code_hash) = 64);

ALTER TABLE public.invite_codes DROP COLUMN code;

COMMENT ON TABLE public.invite_codes IS
  'Invite codes are stored as sha256 hashes only. Plaintext is visible to the
   admin once at creation time via admin_create_invite_code RPC, never afterward.';

-- =============================================
-- 5. Helper: canonicalize a code (upper, strip whitespace) before hashing
-- so users entering "abc-123" vs "ABC 123" vs " abc123" all resolve the same.
-- =============================================
CREATE OR REPLACE FUNCTION private.canonicalize_invite_code(p_code text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT upper(regexp_replace(coalesce(p_code, ''), '[\s\-_]', '', 'g'));
$$;

REVOKE ALL ON FUNCTION private.canonicalize_invite_code(text) FROM PUBLIC;

-- =============================================
-- 6. Helper: hash a canonicalized code to its lookup key.
-- =============================================
CREATE OR REPLACE FUNCTION private.hash_invite_code(p_code text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT encode(extensions.digest(private.canonicalize_invite_code(p_code), 'sha256'), 'hex');
$$;

REVOKE ALL ON FUNCTION private.hash_invite_code(text) FROM PUBLIC;

-- =============================================
-- 7. Helper: is this email_hash rate-limited?
-- More than 5 failed attempts in the last 5 minutes triggers a cooldown.
-- =============================================
CREATE OR REPLACE FUNCTION private.is_invite_rate_limited(p_email_hash text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT count(*) >= 5
  FROM public.invite_redemption_attempts
  WHERE email_hash = p_email_hash
    AND attempted_at > now() - interval '5 minutes'
    AND succeeded = false;
$$;

REVOKE ALL ON FUNCTION private.is_invite_rate_limited(text) FROM PUBLIC;

-- =============================================
-- 8. Rewrite redeem_invite_for_email to use hashed lookup.
--    - Take FOR UPDATE on the invite_codes row before decrementing capacity
--      so concurrent redeems can't both pass the used_count < max_uses check.
--    - Log every attempt to invite_redemption_attempts (success or failure).
--    - Refuse fast if email_hash is rate-limited.
-- =============================================
CREATE OR REPLACE FUNCTION public.redeem_invite_for_email(p_code text, p_email text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_canonical_email text;
  v_email_hash      text;
  v_code_hash       text;
  v_invite_row_id   uuid;
  v_invite_used     int;
  v_invite_max      int;
  v_invite_expires  timestamptz;
  v_existing_hash   text;
BEGIN
  v_canonical_email := lower(btrim(coalesce(p_email, '')));

  IF v_canonical_email = '' OR coalesce(btrim(p_code), '') = '' THEN
    RETURN false;
  END IF;

  v_email_hash := encode(extensions.digest(v_canonical_email, 'sha256'), 'hex');
  v_code_hash  := private.hash_invite_code(p_code);

  IF private.is_invite_rate_limited(v_email_hash) THEN
    -- Don't log this as a failed attempt (would compound). Just refuse.
    RETURN false;
  END IF;

  -- Idempotent re-submit of the same code (already parked) → no work.
  IF EXISTS (
    SELECT 1
    FROM public.pending_invite_claims
    WHERE email = v_canonical_email
      AND invite_code = v_code_hash
      AND claimed_by IS NULL
      AND expires_at > now()
  ) THEN
    RETURN true;
  END IF;

  -- Lock the row before decrementing so two concurrent calls can't both
  -- pass the used_count < max_uses check.
  SELECT id, used_count, max_uses, expires_at
    INTO v_invite_row_id, v_invite_used, v_invite_max, v_invite_expires
  FROM public.invite_codes
  WHERE code_hash = v_code_hash
  FOR UPDATE;

  IF v_invite_row_id IS NULL
     OR v_invite_used >= v_invite_max
     OR (v_invite_expires IS NOT NULL AND v_invite_expires < now()) THEN
    INSERT INTO public.invite_redemption_attempts (email_hash, succeeded)
      VALUES (v_email_hash, false);
    RETURN false;
  END IF;

  -- Refund a prior unclaimed-but-different code for this email.
  SELECT invite_code INTO v_existing_hash
  FROM public.pending_invite_claims
  WHERE email = v_canonical_email
    AND claimed_by IS NULL
    AND expires_at > now()
  LIMIT 1;

  IF v_existing_hash IS NOT NULL AND v_existing_hash <> v_code_hash THEN
    UPDATE public.invite_codes
    SET used_count = GREATEST(used_count - 1, 0)
    WHERE code_hash = v_existing_hash;
  END IF;

  UPDATE public.invite_codes
  SET used_count = used_count + 1
  WHERE id = v_invite_row_id;

  INSERT INTO public.pending_invite_claims (email, invite_code, expires_at, claimed_by, claimed_at, created_at)
  VALUES (v_canonical_email, v_code_hash, now() + interval '2 hours', NULL, NULL, now())
  ON CONFLICT (email) DO UPDATE
    SET invite_code = EXCLUDED.invite_code,
        expires_at  = EXCLUDED.expires_at,
        claimed_by  = NULL,
        claimed_at  = NULL,
        created_at  = now();

  INSERT INTO public.invite_redemption_attempts (email_hash, succeeded)
    VALUES (v_email_hash, true);

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.redeem_invite_for_email(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.redeem_invite_for_email(text, text) TO anon, authenticated;

-- =============================================
-- 9. Rewrite redeem_invite (still service-role only) to use hash + lock.
-- =============================================
CREATE OR REPLACE FUNCTION public.redeem_invite(p_code text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_code_hash      text;
  v_invite_row_id  uuid;
  v_invite_used    int;
  v_invite_max     int;
  v_invite_expires timestamptz;
BEGIN
  IF coalesce(btrim(p_code), '') = '' THEN
    RETURN false;
  END IF;

  v_code_hash := private.hash_invite_code(p_code);

  SELECT id, used_count, max_uses, expires_at
    INTO v_invite_row_id, v_invite_used, v_invite_max, v_invite_expires
  FROM public.invite_codes
  WHERE code_hash = v_code_hash
  FOR UPDATE;

  IF v_invite_row_id IS NULL
     OR v_invite_used >= v_invite_max
     OR (v_invite_expires IS NOT NULL AND v_invite_expires < now()) THEN
    RETURN false;
  END IF;

  UPDATE public.invite_codes
  SET used_count = used_count + 1
  WHERE id = v_invite_row_id;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.redeem_invite(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.redeem_invite(text) TO postgres, service_role;

-- =============================================
-- 10. Admin RPC: generate a new invite code.
-- Generates a 24-char URL-safe random string client-side-visible ONCE
-- via the return value; only the hash is persisted.
-- =============================================
CREATE OR REPLACE FUNCTION public.admin_create_invite_code(
  p_max_uses   int DEFAULT 1,
  p_expires_at timestamptz DEFAULT NULL,
  p_notes      text DEFAULT NULL
)
RETURNS TABLE (
  id         uuid,
  code       text,
  max_uses   int,
  expires_at timestamptz,
  notes      text,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_code       text;
  v_code_hash  text;
  v_id         uuid;
  v_caller     uuid;
  v_alphabet   constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';  -- no 0/1/I/O for legibility
  v_length     constant int  := 24;
  i            int;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_max_uses IS NULL OR p_max_uses < 1 THEN
    RAISE EXCEPTION 'max_uses must be >= 1' USING ERRCODE = '22023';
  END IF;

  -- Build a 24-char URL-safe code. 32 alphabet chars ^ 24 ≈ 2^120 entropy.
  v_code := '';
  FOR i IN 1..v_length LOOP
    v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
  END LOOP;

  v_code_hash := private.hash_invite_code(v_code);
  v_caller    := auth.uid();

  INSERT INTO public.invite_codes (code_hash, max_uses, expires_at, notes, created_by, created_at)
  VALUES (v_code_hash, p_max_uses, p_expires_at, p_notes, v_caller, now())
  RETURNING public.invite_codes.id INTO v_id;

  RETURN QUERY
  SELECT
    v_id,
    v_code,                -- visible to the caller exactly once
    p_max_uses,
    p_expires_at,
    p_notes,
    now()::timestamptz;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_create_invite_code(int, timestamptz, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_invite_code(int, timestamptz, text) TO authenticated;

-- =============================================
-- 11. Pruning: invite_redemption_attempts grows forever otherwise.
-- Schedule a daily cleanup of rows older than 30 days.
-- =============================================
DO $$
BEGIN
  BEGIN
    PERFORM cron.unschedule('invite-attempts-prune-daily');
  EXCEPTION
    WHEN undefined_object THEN NULL;
    WHEN OTHERS THEN
      RAISE WARNING 'Unexpected error unscheduling invite-attempts-prune-daily: %', SQLERRM;
  END;
  PERFORM cron.schedule(
    'invite-attempts-prune-daily',
    '0 3 * * *',
    $sql$DELETE FROM public.invite_redemption_attempts WHERE attempted_at < now() - interval '30 days';$sql$
  );
END $$;

COMMIT;
