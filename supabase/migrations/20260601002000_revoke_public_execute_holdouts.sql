-- Follow-up to 20260601001900_function_grants_lockdown: a few functions still
-- carry the implicit `EXECUTE TO PUBLIC` grant that Postgres applies on every
-- new function. That grant trumps the role-scoped REVOKE in the prior
-- migration (anon inherits PUBLIC), so the advisor kept flagging them.
--
-- handle_new_user is a trigger function with zero RPC callers; PUBLIC EXECUTE
-- is pure noise. plan_events_first_nonempty_window already has an explicit
-- grant to `authenticated`, so dropping PUBLIC closes the anon hole without
-- breaking signed-in callers.

BEGIN;

REVOKE EXECUTE ON FUNCTION public.handle_new_user() FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.plan_events_first_nonempty_window(
  uuid, date, uuid, double precision, double precision, integer, text, integer, integer
) FROM PUBLIC;

COMMIT;
