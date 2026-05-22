-- events_published_city_start_id_idx was created in 007001 but is identical to
-- events_published_feed_idx (same columns + WHERE predicate) from 006800.
-- Drop the newer duplicate; keep events_published_feed_idx.

DROP INDEX IF EXISTS public.events_published_city_start_id_idx;
