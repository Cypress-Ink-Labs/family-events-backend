-- Grant USAGE on the `private` schema to service_role so the public
-- SECURITY INVOKER wrappers introduced in 20260601005100 can resolve the
-- private.* function names when called by the edge functions
-- (process-source-queue, process-tag-queue) and other service-role callers.
-- ----------------------------------------------------------------
-- Migration 20260601002200 granted USAGE on schema `private` to anon +
-- authenticated for the first batch of wrappers (invites_required, etc.).
-- 20260601005100 wrapped 11 queue/maintenance RPCs whose callers are
-- service_role (edge workers) and postgres (pg_cron), but USAGE was never
-- extended to service_role. Result: every public.claim_source_scrape_queue_batch()
-- call from the worker hits `ERROR 42501: permission denied for schema private`
-- at name-resolution time and the worker returns 500. Pending queue rows
-- pile up because nothing can claim them.
--
-- USAGE confers no implicit privileges on contained objects — each private
-- function still requires an explicit EXECUTE grant (already in 005100) —
-- so opening the schema to service_role does not enlarge the attack surface
-- beyond what the EXECUTE grants already permit.

BEGIN;

GRANT USAGE ON SCHEMA private TO service_role;

COMMIT;
