BEGIN;

/*
  Scrape now seeds event coordinates immediately (best effort geocode with city
  centroid fallback). Rows that still hold exact city-centroid coordinates are
  placeholders and should stay eligible for enrichment so precise geocodes can
  overwrite them.
*/

CREATE OR REPLACE FUNCTION private.list_events_needing_enrichment(p_limit int DEFAULT 25)
RETURNS TABLE (
  event_id      uuid,
  title         text,
  description   text,
  venue_name    text,
  address       text,
  city_id       uuid,
  source_id     uuid,
  source_url    text,
  needs_coords  boolean,
  needs_images  boolean,
  admin_locked_fields text[]
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    e.id,
    e.title,
    e.description,
    e.venue_name,
    e.address,
    e.city_id,
    e.source_id,
    e.source_url,
    (
      (
        e.latitude IS NULL
        OR e.longitude IS NULL
        OR (
          c.latitude IS NOT NULL
          AND c.longitude IS NOT NULL
          AND e.latitude IS NOT NULL
          AND e.longitude IS NOT NULL
          AND abs(e.latitude - c.latitude) < 0.000001
          AND abs(e.longitude - c.longitude) < 0.000001
        )
      )
      AND NOT 'latitude'  = ANY(e.admin_locked_fields)
      AND NOT 'longitude' = ANY(e.admin_locked_fields)
    ) AS needs_coords,
    (
      (e.images = '[]'::jsonb OR jsonb_array_length(e.images) = 0)
      AND NOT 'images' = ANY(e.admin_locked_fields)
    ) AS needs_images,
    e.admin_locked_fields
  FROM public.events e
  LEFT JOIN public.cities c ON c.id = e.city_id
  WHERE (
    (
      (
        e.latitude IS NULL
        OR e.longitude IS NULL
        OR (
          c.latitude IS NOT NULL
          AND c.longitude IS NOT NULL
          AND e.latitude IS NOT NULL
          AND e.longitude IS NOT NULL
          AND abs(e.latitude - c.latitude) < 0.000001
          AND abs(e.longitude - c.longitude) < 0.000001
        )
      )
      AND NOT 'latitude'  = ANY(e.admin_locked_fields)
      AND NOT 'longitude' = ANY(e.admin_locked_fields)
    )
    OR (
      (e.images = '[]'::jsonb OR jsonb_array_length(e.images) = 0)
      AND NOT 'images' = ANY(e.admin_locked_fields)
    )
  )
  ORDER BY e.created_at DESC
  LIMIT GREATEST(1, LEAST(p_limit, 100));
$$;

COMMIT;
