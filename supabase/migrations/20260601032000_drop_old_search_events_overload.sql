-- Fix PGRST203: PostgREST cannot disambiguate between overloaded functions.
--
-- Two functions were affected:
--   1. search_events — 028000 migration added (p_lat, p_lng, p_radius_km) params
--   2. admin_update_event — 021000 migration added (p_decision_reason) param
--
-- Both used CREATE OR REPLACE, but since signatures differ, Postgres kept BOTH.
-- Drop the old overloads so only the superset signatures remain.

-- 1) search_events: drop the 14-param version (no radius)
DROP FUNCTION IF EXISTS public.search_events(
  uuid,                     -- p_city_id
  timestamptz,              -- p_date_from
  timestamptz,              -- p_date_to
  integer,                  -- p_age_min
  integer,                  -- p_age_max
  boolean,                  -- p_is_free
  boolean,                  -- p_is_featured
  text[],                   -- p_tag_slugs
  text,                     -- p_keyword
  text,                     -- p_status
  integer,                  -- p_limit
  integer,                  -- p_offset
  timestamptz,              -- p_after_start_datetime
  uuid                      -- p_after_id
);

-- 2) admin_update_event: drop the 4-param version (no decision_reason)
DROP FUNCTION IF EXISTS public.admin_update_event(
  uuid,                     -- p_event_id
  jsonb,                    -- p_patch
  uuid[],                   -- p_tag_ids
  boolean                   -- p_lock_edited_fields
);
