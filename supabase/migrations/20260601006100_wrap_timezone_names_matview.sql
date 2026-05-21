/*
  # Hide the timezone_names materialized view behind a regular view

  Closes advisor lint 0016_materialized_view_in_api for
  `public.timezone_names`. The lint flags materialized views that are
  selectable by anon/authenticated because PostgREST exposes them through
  the Data API; refreshes can lag, statistics are not auto-updated, and
  RLS does not apply.

  Solution: keep the cache as a materialized view in the `private` schema,
  expose a thin SECURITY INVOKER public.timezone_names *view* (regular,
  not materialized) that selects from the private cache. PostgREST sees
  a regular view, the advisor stops complaining, and callers keep the
  same `public.timezone_names` table-like surface with no client changes.

  - Renames `public.timezone_names` -> `private.timezone_names_cache`
  - Replaces `public.timezone_names` with a one-column view
  - Updates `private.refresh_timezone_names()` to refresh the renamed
    cache (the function pinned search_path = '' so the explicit
    schema qualification stays in scope).
  - Re-grants SELECT on the new public view to anon, authenticated,
    service_role so the dropdown query keeps working.
*/

BEGIN;

-- Drop dependent grants on the old object to keep ALTER clean.
REVOKE ALL ON public.timezone_names FROM anon, authenticated, service_role;

ALTER MATERIALIZED VIEW public.timezone_names         RENAME TO timezone_names_cache;
ALTER MATERIALIZED VIEW public.timezone_names_cache   SET SCHEMA private;

-- The unique index moved with the matview but its name still has the old
-- table reference; rename for consistency (purely cosmetic).
ALTER INDEX IF EXISTS private.timezone_names_name_uidx
  RENAME TO timezone_names_cache_name_uidx;

CREATE OR REPLACE VIEW public.timezone_names AS
  SELECT name FROM private.timezone_names_cache;

COMMENT ON VIEW public.timezone_names IS
  'Read-only passthrough of private.timezone_names_cache. Hides the
   underlying materialized view from the Data API (advisor lint 0016)
   while preserving the public.timezone_names interface used by the
   admin timezone dropdown.';

GRANT SELECT ON public.timezone_names TO anon, authenticated, service_role;

-- The refresh function now targets the moved cache.
CREATE OR REPLACE FUNCTION private.refresh_timezone_names()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  REFRESH MATERIALIZED VIEW CONCURRENTLY private.timezone_names_cache;
$$;

REVOKE ALL ON FUNCTION private.refresh_timezone_names() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.refresh_timezone_names()
  TO postgres, service_role;

COMMIT;
