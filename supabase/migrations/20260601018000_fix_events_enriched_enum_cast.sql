-- =============================================================================
-- Migration: Fix events_enriched() for event_status enum
-- =============================================================================
--
-- The events.status column was changed from text to event_status enum.
-- The events_enriched() function compared e.status = p_status (text),
-- which fails because PostgreSQL doesn't auto-cast enum = text.
--
-- Fix: cast p_status to event_status in the WHERE clause, and cast
-- e.status to text in the SELECT output (return type is still text).
--
-- Also drops the old overload (with p_offset) that was accidentally
-- left behind, causing PostgREST PGRST203 overload ambiguity errors.
-- =============================================================================

-- Drop the old overload with p_offset (replaced by cursor-based pagination)
DROP FUNCTION IF EXISTS public.events_enriched(uuid, text, integer, integer, uuid, uuid[], timestamptz, timestamptz);

CREATE OR REPLACE FUNCTION public.events_enriched(
  p_city_id uuid DEFAULT NULL,
  p_status text DEFAULT 'published',
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0,
  p_user_id uuid DEFAULT NULL,
  p_event_ids uuid[] DEFAULT NULL,
  p_date_from timestamptz DEFAULT NULL,
  p_date_to timestamptz DEFAULT NULL
)
RETURNS TABLE(
  id uuid, title text, description text,
  start_datetime timestamptz, end_datetime timestamptz, timezone text,
  venue_name text, address text, city_id uuid,
  latitude numeric, longitude numeric,
  age_min integer, age_max integer, price numeric, is_free boolean,
  source_url text, source_name text, source_id uuid,
  images jsonb, status text,
  ai_confidence numeric, ai_tag_provider text, recurrence_info jsonb,
  is_featured boolean, view_count integer,
  search_vector tsvector, created_at timestamptz, updated_at timestamptz,
  avg_rating numeric, rating_count integer, tags jsonb,
  is_favorited boolean, is_in_calendar boolean
)
LANGUAGE sql STABLE
SET search_path TO ''
AS $$
  SELECT
    e.id, e.title, e.description, e.start_datetime, e.end_datetime, e.timezone,
    e.venue_name, e.address, e.city_id, e.latitude, e.longitude,
    e.age_min, e.age_max, e.price, e.is_free,
    e.source_url, e.source_name, e.source_id, e.images, e.status::text,
    e.ai_confidence, e.ai_tag_provider, e.recurrence_info, e.is_featured, e.view_count,
    e.search_vector, e.created_at, e.updated_at,
    COALESCE(rs.avg_score, 0)::numeric    AS avg_rating,
    COALESCE(rs.rating_count, 0)::int     AS rating_count,
    COALESCE(ts.tags, '[]'::jsonb)        AS tags,
    (p_user_id IS NOT NULL AND f.event_id IS NOT NULL)  AS is_favorited,
    (p_user_id IS NOT NULL AND c.event_id IS NOT NULL)  AS is_in_calendar
  FROM public.events e
  LEFT JOIN LATERAL (
    SELECT ROUND(AVG(r.score)::numeric, 1) AS avg_score,
           COUNT(*)::int AS rating_count
    FROM public.ratings r
    WHERE r.event_id = e.id
  ) rs ON TRUE
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(
             jsonb_build_object('id', t.id, 'name', t.name, 'slug', t.slug, 'color', t.color)
             ORDER BY t.name
           ) AS tags
    FROM public.event_tags et
    JOIN public.tags t ON t.id = et.tag_id
    WHERE et.event_id = e.id
  ) ts ON TRUE
  LEFT JOIN public.favorites f
    ON p_user_id IS NOT NULL AND f.event_id = e.id AND f.user_id = p_user_id
  LEFT JOIN public.user_calendar_events c
    ON p_user_id IS NOT NULL AND c.event_id = e.id AND c.user_id = p_user_id
  WHERE
    (p_date_from IS NULL OR e.start_datetime >= p_date_from)
    AND (p_date_to IS NULL OR e.start_datetime <= p_date_to)
    AND (
      p_event_ids IS NOT NULL AND e.id = ANY(p_event_ids)
      OR p_event_ids IS NULL
        AND e.status = p_status::public.event_status
        AND (p_city_id IS NULL OR e.city_id = p_city_id)
    )
  ORDER BY e.start_datetime ASC
  LIMIT  CASE WHEN p_event_ids IS NULL THEN p_limit  ELSE NULL END
  OFFSET CASE WHEN p_event_ids IS NULL THEN p_offset ELSE 0    END;
$$;
