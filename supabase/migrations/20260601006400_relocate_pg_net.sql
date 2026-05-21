/*
  # Relocate pg_net out of the public schema

  pg_net is marked `extrelocatable = false`, so `ALTER EXTENSION pg_net
  SET SCHEMA extensions` fails with ERROR 0A000. The only way to move
  the catalog entry is DROP + CREATE.

  Safe because:
  - The extension owns a dedicated `net` schema. DROP destroys it and
    everything in it (`net.http_post`, `net._http_response`,
    `net.http_request_queue`, background worker). CREATE recreates the
    schema and re-installs all of it under the same names. Functions
    that call `net.http_post(...)` from plpgsql resolve dynamically at
    statement time, so they keep working without code changes.
  - net.http_request_queue is verified empty before applying (no
    in-flight requests to lose). net._http_response history (~2 rows)
    is acceptable to drop.
  - WITH SCHEMA extensions parks the catalog row under `extensions`,
    which is what advisor lint 0014 wants. The auto-created `net`
    schema is unaffected by that flag.

  Closes advisor lint 0014_extension_in_public for pg_net.
*/

BEGIN;

DROP EXTENSION pg_net;
CREATE EXTENSION pg_net WITH SCHEMA extensions;

COMMIT;
