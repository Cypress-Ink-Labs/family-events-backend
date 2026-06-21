-- Rollback for 20260620030000_plan_events_for_user_range.sql
--
-- Drops public.plan_events_for_user_range and its service_role grant.
-- The original public.plan_events_for_user() is NOT affected (additive migration).

DROP FUNCTION IF EXISTS public.plan_events_for_user_range(
  uuid, timestamptz, timestamptz, uuid[], double precision, double precision,
  integer, text, integer
);
