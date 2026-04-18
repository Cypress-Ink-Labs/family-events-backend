/*
  # Invite code gatekeeping for closed beta

  Schema + RPCs for code-based signup during pre-launch. Public routes
  (/explore, /events/:id) remain open; only signup is gated.

  Flow:
    1. Client calls public.invites_required() to learn if gating is on
    2. If required, client calls public.redeem_invite(code) before auth.signUp
    3. Atomic UPDATE increments used_count if code valid + unexpired + under max_uses
    4. On true → auth.signUp proceeds. On false → signup blocked.

  Toggle the gate without a code change:
    ALTER DATABASE postgres SET app.settings.require_invite = 'true';  -- or 'false'
*/

-- ────────────────────────────────────────────────────────────────────────────
-- Table
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.invite_codes (
  code text PRIMARY KEY,
  max_uses int NOT NULL DEFAULT 1 CHECK (max_uses > 0),
  used_count int NOT NULL DEFAULT 0 CHECK (used_count >= 0),
  expires_at timestamptz,
  notes text,
  created_by uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.invite_codes IS
  'Beta signup gate. Admins generate codes, signup consumes them atomically via redeem_invite RPC.';

ALTER TABLE public.invite_codes ENABLE ROW LEVEL SECURITY;

-- Only admins can read/manage codes. Anonymous users redeem via the RPC,
-- which runs SECURITY DEFINER and never exposes the table contents.
DROP POLICY IF EXISTS "Admins can manage invite codes" ON public.invite_codes;
CREATE POLICY "Admins can manage invite codes"
  ON public.invite_codes FOR ALL
  TO authenticated
  USING (private.is_admin())
  WITH CHECK (private.is_admin());

-- ────────────────────────────────────────────────────────────────────────────
-- redeem_invite(code) → boolean
--
-- Atomic UPDATE that consumes one use of the code if valid. Returns true on
-- success, false if code is invalid / expired / exhausted.
--
-- Anon + authenticated can call it. The table is RLS-locked, but SECURITY
-- DEFINER bypasses that for this one controlled path.
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.redeem_invite(p_code text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  rows_updated int;
BEGIN
  IF p_code IS NULL OR btrim(p_code) = '' THEN
    RETURN false;
  END IF;

  UPDATE public.invite_codes
  SET used_count = used_count + 1
  WHERE code = btrim(p_code)
    AND used_count < max_uses
    AND (expires_at IS NULL OR expires_at > now());

  GET DIAGNOSTICS rows_updated = ROW_COUNT;
  RETURN rows_updated > 0;
END;
$$;

COMMENT ON FUNCTION public.redeem_invite IS
  'Atomically consume one use of an invite code. Returns true on success.';

REVOKE ALL ON FUNCTION public.redeem_invite(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.redeem_invite(text) TO anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- invites_required() → boolean
--
-- Tiny config-reader so the client can decide whether to show the code field.
-- Reads app.settings.require_invite — set via ALTER DATABASE (see setup-local).
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.invites_required()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(current_setting('app.settings.require_invite', true), 'false') = 'true';
$$;

COMMENT ON FUNCTION public.invites_required IS
  'Returns true when app.settings.require_invite is enabled (gate is on).';

GRANT EXECUTE ON FUNCTION public.invites_required() TO anon, authenticated;
