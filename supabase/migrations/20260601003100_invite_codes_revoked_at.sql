-- Add revoked_at to invite_codes, gate redeem RPCs against revoked rows,
-- and provide an admin_revoke_invite_code RPC (private body + public wrapper).
--
-- NOTE: After migration 20260601002100, the real function bodies for
-- redeem_invite_for_email and redeem_invite live in the `private` schema.
-- The `public` wrappers are thin SECURITY INVOKER SQL delegates and are NOT
-- changed here (they already route to private.*).

BEGIN;

ALTER TABLE public.invite_codes
  ADD COLUMN IF NOT EXISTS revoked_at timestamptz;

COMMENT ON COLUMN public.invite_codes.revoked_at IS
  'When non-null, the row is revoked and cannot be redeemed. Set via
   admin_revoke_invite_code RPC; once set it is one-way.';

-- =============================================
-- Refresh private.redeem_invite_for_email to reject revoked codes.
-- Adds v_invite_revoked variable and gates the guard on revoked_at IS NOT NULL.
-- =============================================
CREATE OR REPLACE FUNCTION private.redeem_invite_for_email(p_code text, p_email text)
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
  v_invite_revoked  timestamptz;
  v_existing_hash   text;
BEGIN
  v_canonical_email := lower(btrim(coalesce(p_email, '')));

  IF v_canonical_email = '' OR coalesce(btrim(p_code), '') = '' THEN
    RETURN false;
  END IF;

  v_email_hash := encode(extensions.digest(v_canonical_email, 'sha256'), 'hex');
  v_code_hash  := private.hash_invite_code(p_code);

  IF private.is_invite_rate_limited(v_email_hash) THEN
    RETURN false;
  END IF;

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

  SELECT id, used_count, max_uses, expires_at, revoked_at
    INTO v_invite_row_id, v_invite_used, v_invite_max, v_invite_expires, v_invite_revoked
  FROM public.invite_codes
  WHERE code_hash = v_code_hash
  FOR UPDATE;

  IF v_invite_row_id IS NULL
     OR v_invite_revoked IS NOT NULL
     OR v_invite_used >= v_invite_max
     OR (v_invite_expires IS NOT NULL AND v_invite_expires < now()) THEN
    INSERT INTO public.invite_redemption_attempts (email_hash, succeeded)
      VALUES (v_email_hash, false);
    RETURN false;
  END IF;

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

-- Keep grants identical to the original migration.
REVOKE EXECUTE ON FUNCTION private.redeem_invite_for_email(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.redeem_invite_for_email(text, text) TO anon, authenticated, service_role;

-- =============================================
-- Refresh private.redeem_invite (service_role only) with the same gate.
-- =============================================
CREATE OR REPLACE FUNCTION private.redeem_invite(p_code text)
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
  v_invite_revoked timestamptz;
BEGIN
  IF coalesce(btrim(p_code), '') = '' THEN
    RETURN false;
  END IF;

  v_code_hash := private.hash_invite_code(p_code);

  SELECT id, used_count, max_uses, expires_at, revoked_at
    INTO v_invite_row_id, v_invite_used, v_invite_max, v_invite_expires, v_invite_revoked
  FROM public.invite_codes
  WHERE code_hash = v_code_hash
  FOR UPDATE;

  IF v_invite_row_id IS NULL
     OR v_invite_revoked IS NOT NULL
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

REVOKE EXECUTE ON FUNCTION private.redeem_invite(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.redeem_invite(text) TO postgres, service_role;

-- =============================================
-- admin_revoke_invite_code: private body + public wrapper convention.
-- private.admin_revoke_invite_code does the privileged write under
-- SECURITY DEFINER; public.admin_revoke_invite_code is a thin
-- SECURITY INVOKER wrapper.
-- =============================================
CREATE OR REPLACE FUNCTION private.admin_revoke_invite_code(p_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_updated int;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  UPDATE public.invite_codes
  SET revoked_at = now()
  WHERE id = p_id
    AND revoked_at IS NULL;

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated > 0;
END;
$$;

REVOKE ALL ON FUNCTION private.admin_revoke_invite_code(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.admin_revoke_invite_code(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_revoke_invite_code(p_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.admin_revoke_invite_code(p_id);
$$;

REVOKE EXECUTE ON FUNCTION public.admin_revoke_invite_code(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_revoke_invite_code(uuid) TO authenticated, service_role;

COMMIT;
