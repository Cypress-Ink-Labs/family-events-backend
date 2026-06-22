-- Rollback for 20260620050000_set_preferred_cities_rpc.sql
--
-- Drops public.set_preferred_cities and its authenticated grant. No other
-- objects are affected (the migration is purely additive — it only creates
-- this function).

DROP FUNCTION IF EXISTS public.set_preferred_cities(uuid[], uuid);
