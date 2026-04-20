/*
  # Wave 2.3 — events_enriched RPC: add p_event_ids / p_date_from / p_date_to

  Extends Wave 2.1's `public.events_enriched` so the my-events, event-detail,
  and calendar-view pages can reuse the single enriched RPC instead of round-
  tripping events + ratings + tags + favorites + calendar separately.

  ## New parameters
  - `p_event_ids uuid[] DEFAULT NULL` — when non-null, returns rows WHERE
    `e.id = ANY(p_event_ids)` and intentionally ignores `p_city_id`,
    `p_status`, `p_limit`, `p_offset`. This is the "give me these specific
    events, enriched" path used by my-events (saved-ids fetch) and
    event-detail (single-id fetch).
  - `p_date_from timestamptz DEFAULT NULL` — inclusive lower bound on
    `e.start_datetime`. Ignored when NULL.
  - `p_date_to timestamptz DEFAULT NULL` — inclusive upper bound on
    `e.start_datetime`. Ignored when NULL. Used by calendar-view for
    month-scoped fetches.

  ## Precedence
  `p_event_ids` is the dominant filter: when it is non-null, the other
  scalar filters (city/status/limit/offset) are bypassed so callers who
  need specific event IDs never have to guess a big-enough LIMIT or worry
  about the default `status='published'` filter hiding a draft they own.
  Date bounds DO still apply to `p_event_ids` calls; they are cheap and
  symmetrically useful for all three call paths.

  ## Signature evolution
  Wave 2.1 shipped the 5-param signature (city, status, limit, offset,
  user_id). PostgreSQL overloads functions by signature, so a bare
  `CREATE OR REPLACE FUNCTION ... (..., new_params)` would leave TWO
  `events_enriched` functions sitting side-by-side. Single canonical
  function is a hard requirement for this wave, so we explicitly DROP the
  5-param signature before CREATE OR REPLACE'ing the 8-param one. The
  rollback inverts this exactly (drop 8, recreate 5).

  ## Return shape
  Unchanged from Wave 2.1-fix-up — same 32 columns, same ai_tag_provider
  surfacing, same COALESCE defaults for avg_rating/rating_count/tags.

  ## Running tests
  After `supabase db reset`:

    PGPASSWORD=postgres psql -h 127.0.0.1 -p 55322 -U postgres -d postgres \
      -v ON_ERROR_STOP=1 -f supabase/tests/events_enriched_parity.sql
*/

DROP FUNCTION IF EXISTS public.events_enriched(uuid, text, int, int, uuid);

CREATE OR REPLACE FUNCTION public.events_enriched(
  p_city_id uuid DEFAULT NULL,
  p_status text DEFAULT 'published',
  p_limit int DEFAULT 100,
  p_offset int DEFAULT 0,
  p_user_id uuid DEFAULT NULL,
  p_event_ids uuid[] DEFAULT NULL,
  p_date_from timestamptz DEFAULT NULL,
  p_date_to timestamptz DEFAULT NULL
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
  WHERE
    (p_date_from IS NULL OR e.start_datetime >= p_date_from)
    AND (p_date_to IS NULL OR e.start_datetime <= p_date_to)
    AND (
      p_event_ids IS NOT NULL
        AND e.id = ANY(p_event_ids)
      OR p_event_ids IS NULL
        AND e.status = p_status
        AND (p_city_id IS NULL OR e.city_id = p_city_id)
    )
  ORDER BY e.start_datetime ASC
  LIMIT CASE WHEN p_event_ids IS NULL THEN p_limit ELSE NULL END
  OFFSET CASE WHEN p_event_ids IS NULL THEN p_offset ELSE 0 END;
$$;

COMMENT ON FUNCTION public.events_enriched(uuid, text, int, int, uuid, uuid[], timestamptz, timestamptz) IS
  'Wave 2.3 — single-call enrichment for event list + detail + calendar pages. SECURITY INVOKER: RLS gates access. p_event_ids overrides p_city_id/p_status/p_limit/p_offset (specific-IDs fetch). p_date_from/p_date_to are INCLUSIVE bounds on start_datetime and apply to all call paths. avg_rating/rating_count/tags default to 0/0/[] (never NULL). is_favorited/is_in_calendar return false when p_user_id IS NULL.';

GRANT EXECUTE ON FUNCTION public.events_enriched(uuid, text, int, int, uuid, uuid[], timestamptz, timestamptz)
  TO anon, authenticated;
