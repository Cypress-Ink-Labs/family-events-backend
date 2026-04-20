/*
  # Wave 2.1 — events_enriched RPC + supporting composite indexes

  Collapses the five-call client-side fan-out in `src/lib/enrich-events.ts`
  (events + tags + ratings + favorites + calendar) into a single Postgres
  call. SECURITY INVOKER so RLS on underlying tables still gates access.

  ## Returned row (superset of enrich-events.ts output)
  - All public.events columns
  - avg_rating numeric — 0 when the event has no ratings (NEVER NULL)
  - rating_count int — 0 when the event has no ratings (NEVER NULL)
  - tags jsonb — array of {id, name, slug, color}; '[]' when no tags
  - is_favorited bool — false for anon or when p_user_id IS NULL
  - is_in_calendar bool — false for anon or when p_user_id IS NULL

  ## Indexes
  Adds two composite indexes needed by the typical RPC call paths:
  ORDER BY start_datetime after filtering by status, and city-scoped
  ORDER BY start_datetime.

  Skipped (already covered — verified via pg_indexes before shipping):
  - events(status, start_datetime): NOT present → added below
  - events(city_id, start_datetime): NOT present → added below
  - event_tags(event_id): covered by PRIMARY KEY (event_id, tag_id)
  - ratings(event_id): covered by ratings_event_id_idx
  - favorites(user_id, event_id): covered by favorites_user_id_event_id_key (UNIQUE)
  - user_calendar_events(user_id, event_id): covered by
    user_calendar_events_user_id_event_id_key (UNIQUE)

  ## CONCURRENTLY
  Intentionally omitted. Supabase's migration harness wraps each file in a
  transaction, and CREATE INDEX CONCURRENTLY cannot run inside a transaction
  block. IF NOT EXISTS still gives idempotency; the tables are small enough
  at current scale that a short lock is acceptable. Revisit if a future
  migration needs zero-downtime index creation.

  ## Running tests
  After `supabase db reset`, run the parity test with:

    PGPASSWORD=postgres psql -h 127.0.0.1 -p 55322 -U postgres -d postgres \
      -v ON_ERROR_STOP=1 -f supabase/tests/events_enriched_parity.sql

  (matches the rls_*.sql test harness convention).
*/

-- =============================================================================
-- Composite indexes
-- =============================================================================
CREATE INDEX IF NOT EXISTS events_status_start_datetime_idx
  ON public.events(status, start_datetime);

CREATE INDEX IF NOT EXISTS events_city_id_start_datetime_idx
  ON public.events(city_id, start_datetime);

-- =============================================================================
-- events_enriched RPC
-- =============================================================================
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
