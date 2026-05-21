/*
  # Mark the timezone_names view as SECURITY INVOKER

  Closes advisor lint 0010_security_definer_view introduced when
  20260601006100 added the regular view `public.timezone_names` to
  hide the underlying materialized view. In Postgres 15+, views default
  to DEFINER semantics (the view executes with the view owner's
  permissions, bypassing RLS). The advisor flags this even for a public
  read-only timezone list because the pattern is unsafe by default.

  With `security_invoker = true` the view runs as the caller, so anon /
  authenticated / service_role need their own SELECT privilege on the
  underlying `private.timezone_names_cache` materialized view. They
  already have USAGE on `private` (granted by 20260601002200 +
  20260601005600); grant SELECT on the cache to finish the chain.

  Net result: same client-facing behavior, no SECURITY DEFINER, and
  the underlying object stays in `private` so advisor 0016 is unaffected.
*/

BEGIN;

ALTER VIEW public.timezone_names SET (security_invoker = true);

GRANT SELECT ON private.timezone_names_cache
  TO anon, authenticated, service_role;

COMMIT;
