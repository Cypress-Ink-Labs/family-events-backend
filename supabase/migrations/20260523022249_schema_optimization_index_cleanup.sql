-- Safe redundant index cleanup from docs/database/schema-optimization-tasks.md.
-- This environment is not live, so immediate cleanup is acceptable.
DROP INDEX IF EXISTS public.events_published_city_start_datetime_idx;
DROP INDEX IF EXISTS public.recommendation_signals_user_id_idx;
DROP INDEX IF EXISTS public.user_calendar_events_user_id_idx;
