-- Lock down search_path on the user_access audit trigger function.
-- Closes advisor lint 0011_function_search_path_mutable for
-- private.user_access_set_audit_timestamps.
--
-- Trigger functions with a mutable search_path are an injection surface:
-- a privileged caller's session could prepend a malicious schema to its
-- search_path and shadow `now()` or other names referenced by the body.
-- Pinning to empty search_path forces all references to resolve via
-- explicit schema qualification (pg_catalog is always implicit), which
-- makes the function tamper-resistant.

BEGIN;

ALTER FUNCTION private.user_access_set_audit_timestamps() SET search_path = '';

COMMIT;
