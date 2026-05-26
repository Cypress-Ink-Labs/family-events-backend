-- Drop the legacy search_events RPC (v1).
-- This function has zero callers in apps/web/src, zero edge function callers,
-- and is superseded by search_events_v2 (cursor-based pagination).
-- See DECISIONS.md D004 for rationale.

BEGIN;

REVOKE ALL ON FUNCTION public.search_events FROM anon, authenticated;

DROP FUNCTION IF EXISTS public.search_events(
  p_city_id   uuid,
  p_date_from timestamptz,
  p_date_to   timestamptz,
  p_age_min   int,
  p_age_max   int,
  p_is_free   boolean,
  p_is_featured boolean,
  p_tag_slugs text[],
  p_keyword   text,
  p_status    text,
  p_limit     int,
  p_offset    int
);

COMMIT;
