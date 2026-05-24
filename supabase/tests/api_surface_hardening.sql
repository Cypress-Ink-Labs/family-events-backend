/*
  Verifies the production API surface stays explicit:
  - pg_graphql is not installed
  - anonymous users do not retain broad mutation grants on public tables
*/

DO $$
DECLARE
  anon_mutation_grants int;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_graphql') THEN
    RAISE EXCEPTION 'API_SURFACE_FAIL: pg_graphql should not be installed';
  END IF;

  SELECT count(*) INTO anon_mutation_grants
  FROM information_schema.role_table_grants
  WHERE table_schema = 'public'
    AND grantee = 'anon'
    AND privilege_type IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'TRIGGER', 'REFERENCES');

  IF anon_mutation_grants <> 0 THEN
    RAISE EXCEPTION 'API_SURFACE_FAIL: anon still has % public mutation grants', anon_mutation_grants;
  END IF;
END
$$;
