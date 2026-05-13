-- Grant USAGE on the `private` schema to anon + authenticated so the public
-- SECURITY INVOKER wrappers introduced in 20260601002100 can resolve the
-- private.* function names at call time.
-- ----------------------------------------------------------------
-- Postgres name resolution requires USAGE on the containing schema; EXECUTE
-- on the function alone is not enough. Without this grant, anon callers hit
-- `ERROR 42501: permission denied for schema private` the moment a wrapper
-- like public.invites_required tries to SELECT private.invites_required().
--
-- USAGE confers no implicit privileges on contained objects — every private
-- function still requires an explicit EXECUTE grant — so opening the schema
-- to anon/authenticated does not enlarge the attack surface.

BEGIN;

GRANT USAGE ON SCHEMA private TO anon, authenticated;

COMMIT;
