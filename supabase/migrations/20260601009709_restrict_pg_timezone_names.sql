BEGIN;

CREATE OR REPLACE VIEW public.pg_timezone_names
WITH (security_invoker = true) AS
SELECT name
FROM private.timezone_names_cache;

COMMENT ON VIEW public.pg_timezone_names IS
  'Compatibility view for clients that query pg_timezone_names through the Data API. Reads private.timezone_names_cache instead of the slow pg_catalog.pg_timezone_names function scan.';

GRANT SELECT ON TABLE public.pg_timezone_names TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
