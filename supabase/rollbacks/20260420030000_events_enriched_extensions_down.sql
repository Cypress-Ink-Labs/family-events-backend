/*
  # Down migration for 20260420030000_events_enriched_extensions.sql

  Restores the Wave 2.1-fix-up 5-param signature of public.events_enriched.
  Drops the 8-param signature first (PostgreSQL overloads by signature, so
  leaving it around would result in two functions — the exact state the
  forward migration was designed to avoid).

  Apply with:

    PGPASSWORD=postgres psql -h 127.0.0.1 -p 55322 -U postgres -d postgres \
      -v ON_ERROR_STOP=1 \
      -f supabase/rollbacks/20260420030000_events_enriched_extensions_down.sql

  After this runs, `\df public.events_enriched` should show ONE row with the
  5-param signature (uuid, text, int, int, uuid).
*/

DROP FUNCTION IF EXISTS public.events_enriched(uuid, text, int, int, uuid, uuid[], timestamptz, timestamptz);

CREATE OR REPLACE FUNCTION public.events_enriched(
  p_city_id uuid DEFAULT NULL,
  p_status text DEFAULT 'published',
  p_limit int DEFAULT 100,
  p_offset int DEFAULT 0,
  p_user_id uuid DEFAULT NULL
)
RETURNS TABLE (
  id uuid,
  title text,
  description text,
  start_datetime timestamptz,
  end_datetime timestamptz,
  timezone text,
  venue_name text,
  address text,
  city_id uuid,
  latitude numeric,
  longitude numeric,
  age_min int,
  age_max int,
  price numeric,
  is_free boolean,
  source_url text,
  source_name text,
  source_id uuid,
  images jsonb,
  status text,
  ai_confidence numeric,
  ai_tag_provider text,
  recurrence_info jsonb,
  is_featured boolean,
  view_count int,
  search_vector tsvector,
  created_at timestamptz,
  updated_at timestamptz,
  avg_rating numeric,
  rating_count int,
  tags jsonb,
  is_favorited boolean,
  is_in_calendar boolean
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT
    e.id, e.title, e.description, e.start_datetime, e.end_datetime, e.timezone,
    e.venue_name, e.address, e.city_id, e.latitude, e.longitude,
    e.age_min, e.age_max, e.price, e.is_free,
    e.source_url, e.source_name, e.source_id, e.images, e.status,
    e.ai_confidence, e.ai_tag_provider, e.recurrence_info, e.is_featured, e.view_count,
    e.search_vector, e.created_at, e.updated_at,
    COALESCE(rs.avg_score, 0)::numeric AS avg_rating,
    COALESCE(rs.rating_count, 0)::int AS rating_count,
    COALESCE(ts.tags, '[]'::jsonb) AS tags,
    (p_user_id IS NOT NULL AND f.event_id IS NOT NULL) AS is_favorited,
    (p_user_id IS NOT NULL AND c.event_id IS NOT NULL) AS is_in_calendar
  FROM public.events e
  LEFT JOIN LATERAL (
    SELECT ROUND(AVG(r.score)::numeric, 1) AS avg_score,
           COUNT(*)::int AS rating_count
    FROM public.ratings r
    WHERE r.event_id = e.id
  ) rs ON TRUE
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(
             jsonb_build_object(
               'id', t.id,
               'name', t.name,
               'slug', t.slug,
               'color', t.color
             )
             ORDER BY t.name
           ) AS tags
    FROM public.event_tags et
    JOIN public.tags t ON t.id = et.tag_id
    WHERE et.event_id = e.id
  ) ts ON TRUE
  LEFT JOIN public.favorites f
    ON p_user_id IS NOT NULL
    AND f.event_id = e.id
    AND f.user_id = p_user_id
  LEFT JOIN public.user_calendar_events c
    ON p_user_id IS NOT NULL
    AND c.event_id = e.id
    AND c.user_id = p_user_id
  WHERE e.status = p_status
    AND (p_city_id IS NULL OR e.city_id = p_city_id)
  ORDER BY e.start_datetime ASC
  LIMIT p_limit OFFSET p_offset;
$$;

COMMENT ON FUNCTION public.events_enriched(uuid, text, int, int, uuid) IS
  'Wave 2.1 — single-call enrichment for event list pages. SECURITY INVOKER: RLS on events/event_tags/tags/ratings/favorites/user_calendar_events gates all access. avg_rating/rating_count/tags default to 0/0/[] (never NULL). is_favorited/is_in_calendar return false when p_user_id IS NULL.';

GRANT EXECUTE ON FUNCTION public.events_enriched(uuid, text, int, int, uuid)
  TO anon, authenticated;
