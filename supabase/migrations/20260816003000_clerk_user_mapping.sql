-- Migration: 20260816003000_clerk_user_mapping.sql
--
-- Production readiness program U19 (KTD2): identity mapping between existing
-- Supabase auth users and their Clerk accounts. Additive only — no key
-- columns change and the old SPA is unaffected. Consumers:
--   * family-events-app's identity seam (uuid-mapping mode) translates the
--     verified Clerk session ID to the uuid the user-keyed tables still use.
--   * U7 reads this table at cutover to retype user keys to Clerk text IDs.
--
-- Rows are written by scripts/provision-clerk-users.mjs (service role). The
-- table is service-role only: RLS is enabled with no policies and table
-- privileges are revoked from anon/authenticated, so browser clients can
-- neither read nor write it.
--
-- Paired rollback:
--   supabase/rollbacks/20260816003000_clerk_user_mapping_down.sql

CREATE TABLE public.clerk_user_mapping (
  clerk_user_id text PRIMARY KEY,
  supabase_uuid uuid NOT NULL UNIQUE REFERENCES auth.users (id) ON DELETE CASCADE,
  -- Email + role travel for reconciliation diffs against Clerk's user list
  -- (U19 verification); Clerk public metadata stays the role source of truth.
  email text NOT NULL,
  role text NOT NULL DEFAULT 'member',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT clerk_user_mapping_clerk_id_shape_chk CHECK (clerk_user_id ~ '^user_'),
  CONSTRAINT clerk_user_mapping_role_chk CHECK (role IN ('operator', 'member'))
);

COMMENT ON TABLE public.clerk_user_mapping IS
  'U19 (KTD2): supabase auth uuid <-> Clerk user ID mapping. Written by the '
  'provisioning script; read by the new app''s identity seam pre-cutover and '
  'consumed by the U7 key migration. Service-role only (RLS on, no policies).';

ALTER TABLE public.clerk_user_mapping ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.clerk_user_mapping FROM PUBLIC;
REVOKE ALL ON TABLE public.clerk_user_mapping FROM anon;
REVOKE ALL ON TABLE public.clerk_user_mapping FROM authenticated;
GRANT ALL ON TABLE public.clerk_user_mapping TO service_role;
