/*
  Geocodable-address filter for the enrichment claim queue
  --------------------------------------------------------

  The Lafayette libcal source emits ~1180 rows whose `address` field is a room
  label like "Story Time Room, Main Library" instead of a street address.
  Nominatim never returns a hit for those queries, so the enrichment cron
  burned every tick on the same un-geocodable rows while the ~30 events with
  real street addresses sat at the back of the claim queue indefinitely.

  Fix: stop flagging rows as `needs_coords` when the address has no
  geocode-friendly signal. The row stays at city-centroid coords (placeholder),
  the map continues to filter them out via isCityCentroidCoordinate(), and the
  claim queue spends its slots only on rows that can actually progress.

  Address signal heuristic:
    - Starts with a street-number prefix (`^\d+\s+...`), or
    - Contains a street-type word (St, Ave, Blvd, Rd, Dr, Hwy, Pkwy, etc.).

  These rows can still be claimed if they need images (the in-scope image
  RPC is unaffected). And if a future scraper change starts emitting real
  addresses for these sources, the predicate flips automatically.
*/

BEGIN;

DROP FUNCTION IF EXISTS public.list_events_needing_enrichment(int);
DROP FUNCTION IF EXISTS private.list_events_needing_enrichment(int);

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
  admin_locked_fields text[],
  tags          text[]
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH enrichment_flags AS (
    SELECT
      e.*,
      -- Cheap heuristic: real street address has either a leading street
      -- number ("433 Jefferson St") or a recognizable street-type word.
      -- Anything else (room labels, building names alone) won't survive
      -- Nominatim — flagging them as needs_coords just wastes the tick.
      (
        e.address ~ '^\d+\s'
        OR e.address ~* '\m(St|Ave|Blvd|Rd|Dr|Hwy|Pkwy|Way|Ln|Lane|Court|Place|Highway|Parkway|Avenue|Street|Drive|Road|Circle|Cir)\M'
      ) AS _has_geocodable_address,
      (
        (
          e.latitude IS NULL
          OR e.longitude IS NULL
          OR (
            c.latitude IS NOT NULL
            AND c.longitude IS NOT NULL
            AND e.latitude IS NOT NULL
            AND e.longitude IS NOT NULL
            AND abs(e.latitude  - c.latitude)  < 0.000001
            AND abs(e.longitude - c.longitude) < 0.000001
          )
        )
        AND NOT 'latitude'  = ANY(e.admin_locked_fields)
        AND NOT 'longitude' = ANY(e.admin_locked_fields)
      ) AS _coords_unset_or_centroid,
      (
        (e.images = '[]'::jsonb OR jsonb_array_length(e.images) = 0)
        AND NOT 'images' = ANY(e.admin_locked_fields)
      ) AS _needs_images
    FROM public.events e
    LEFT JOIN public.cities c ON c.id = e.city_id
  ),
  event_tag_slugs AS (
    SELECT
      et.event_id,
      array_agg(t.slug ORDER BY et.confidence DESC NULLS LAST, t.slug ASC) AS slugs
    FROM public.event_tags et
    JOIN public.tags t ON t.id = et.tag_id
    GROUP BY et.event_id
  )
  SELECT
    ef.id,
    ef.title,
    ef.description,
    ef.venue_name,
    ef.address,
    ef.city_id,
    ef.source_id,
    ef.source_url,
    -- Only set needs_coords=true when the row is *also* geocodable. Centroid
    -- rows without a real address stay false here so the edge function skips
    -- the Nominatim call entirely.
    (ef._coords_unset_or_centroid AND ef._has_geocodable_address) AS needs_coords,
    ef._needs_images AS needs_images,
    ef.admin_locked_fields,
    COALESCE(ets.slugs, ARRAY[]::text[]) AS tags
  FROM enrichment_flags ef
  LEFT JOIN event_tag_slugs ets ON ets.event_id = ef.id
  WHERE
    (ef._coords_unset_or_centroid AND ef._has_geocodable_address)
    OR ef._needs_images
  ORDER BY ef.last_enrichment_attempt_at ASC NULLS FIRST, ef.created_at DESC
  LIMIT GREATEST(1, LEAST(p_limit, 100));
$$;

REVOKE EXECUTE ON FUNCTION private.list_events_needing_enrichment(int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.list_events_needing_enrichment(int) TO service_role;

CREATE OR REPLACE FUNCTION public.list_events_needing_enrichment(p_limit int DEFAULT 25)
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
  admin_locked_fields text[],
  tags          text[]
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT * FROM private.list_events_needing_enrichment(p_limit);
$$;

REVOKE EXECUTE ON FUNCTION public.list_events_needing_enrichment(int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.list_events_needing_enrichment(int) TO service_role;

COMMIT;
