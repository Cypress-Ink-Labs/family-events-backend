/*
  # Down migration for 20260420020000_events_enriched.sql

  Drops the RPC and the two composite indexes added by the forward migration.
  Pre-existing indexes are NOT touched.

  Apply with:

    PGPASSWORD=postgres psql -h 127.0.0.1 -p 55322 -U postgres -d postgres \
      -v ON_ERROR_STOP=1 \
      -f supabase/rollbacks/20260420020000_events_enriched_down.sql
*/

DROP FUNCTION IF EXISTS public.events_enriched(uuid, text, int, int, uuid);

DROP INDEX IF EXISTS public.events_city_id_start_datetime_idx;
DROP INDEX IF EXISTS public.events_status_start_datetime_idx;
