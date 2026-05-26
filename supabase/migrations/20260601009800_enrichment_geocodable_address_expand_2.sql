/*
  Expand geocodable-address heuristic — round 2 (009800)
  -------------------------------------------------------

  Baseline (009700) added place-type words (Park, Museum, Library, etc.) in
  address/venue_name. This migration adds four more OR clauses to catch:

    (d) Suite/unit indicators in address
          "Suite", "Ste", "Unit", "Apt", "Floor", "Fl", "Bldg", "Building"
          — any real street address long enough to carry a suite number is
            geocodable; libcal room labels never carry these tokens.

    (e) Extended venue / family-event place-types in address
          Gym, Fitness, Studio, Kitchen, Cafe, Restaurant, Bar, Brewery,
          Winery, Club, Lodge, Pavilion, Amphitheater/Amphitheatre, Pool,
          Recreation, Rec
          — adds ~30-60 more Lafayette events that 009700 missed.

    (f) Same extended place-type set applied to venue_name
          Mirrors (e) for events where the place type lives in venue_name
          rather than the address string.

    (g) venue_name that starts with a street number  ("433 Jefferson …")
          Some data sources copy the street address into venue_name; a
          leading digit sequence followed by a space is a strong signal.

  All other structure (RETURNS TABLE columns, SECURITY DEFINER/INVOKER split,
  search_path = '', REVOKE/GRANT block) is identical to 009700.

  Reference: 009700 baseline, 009600 original filter.
*/

-- DIAGNOSTIC QUERY ----------------------------------------------------------
-- Run these before/after applying the migration to measure impact on local
-- seed data.  They satisfy requirement R006 (observability artifact).
--
-- 1. Centroid-stuck count (events with coords equal to city centroid):
--
--    SELECT count(*)
--    FROM public.events e
--    JOIN public.cities c ON c.id = e.city_id
--    WHERE e.latitude  IS NOT NULL
--      AND e.longitude IS NOT NULL
--      AND c.latitude  IS NOT NULL
--      AND c.longitude IS NOT NULL
--      AND abs(e.latitude  - c.latitude)  < 0.000001
--      AND abs(e.longitude - c.longitude) < 0.000001;
--
-- 2. Newly-eligible count added by 009800 patterns (d)–(g):
--
--    SELECT count(*) AS newly_eligible
--    FROM public.events e
--    WHERE
--      -- already eligible via 009700 (exclude to count only NEW additions):
--      NOT (
--        e.address ~ '^\d+\s'
--        OR e.address ~* '\m(St|Ave|Blvd|Rd|Dr|Hwy|Pkwy|Way|Ln|Lane|Court|Place|Highway|Parkway|Avenue|Street|Drive|Road|Circle|Cir)\M'
--        OR e.address ~* '\m(Park|Museum|Library|Center|Centre|Stadium|Field|Gardens|Garden|Hall|Theater|Theatre|Church|School|University|College|Mall|Plaza|Market|Arena|Cathedral|Zoo|Aquarium|Observatory)\M'
--        OR e.venue_name ~* '\m(Park|Museum|Library|Center|Centre|Stadium|Field|Gardens|Garden|Hall|Theater|Theatre|Church|School|University|College|Mall|Plaza|Market|Arena|Cathedral|Zoo|Aquarium|Observatory)\M'
--      )
--      -- newly eligible via 009800:
--      AND (
--        e.address ~* '\m(Suite|Ste|Unit|Apt|Floor|Fl|Bldg|Building)\M'
--        OR e.address ~* '\m(Gym|Fitness|Studio|Kitchen|Cafe|Restaurant|Bar|Brewery|Winery|Club|Lodge|Pavilion|Amphitheater|Amphitheatre|Pool|Recreation|Rec)\M'
--        OR e.venue_name ~* '\m(Gym|Fitness|Studio|Kitchen|Cafe|Restaurant|Bar|Brewery|Winery|Club|Lodge|Pavilion|Amphitheater|Amphitheatre|Pool|Recreation|Rec)\M'
--        OR e.venue_name ~ '^\d+\s'
--      );
-- END DIAGNOSTIC QUERY -------------------------------------------------------

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
      -- Geocode-eligible signals, in order of precision:
      --   (a) Street-number prefix ("433 Jefferson St")            — best
      --   (b) Street-type word in address ("101 W Vermilion St")   — good
      --   (c) Place-type word in address OR venue_name             — fair
      --       (Park, Museum, Library, Center, Stadium, Gardens...)
      --   (d) Suite/unit indicators in address                     — good
      --       (Suite, Ste, Unit, Apt, Floor, Fl, Bldg, Building)
      --   (e) Extended venue place-types in address                — fair
      --       (Gym, Fitness, Studio, Kitchen, Cafe, Restaurant, ...)
      --   (f) Extended venue place-types in venue_name             — fair
      --   (g) venue_name starts with a street number               — good
      -- Anything else (raw room labels with no place noun) stays excluded.
      (
        e.address ~ '^\d+\s'
        OR e.address ~* '\m(St|Ave|Blvd|Rd|Dr|Hwy|Pkwy|Way|Ln|Lane|Court|Place|Highway|Parkway|Avenue|Street|Drive|Road|Circle|Cir)\M'
        OR e.address ~* '\m(Park|Museum|Library|Center|Centre|Stadium|Field|Gardens|Garden|Hall|Theater|Theatre|Church|School|University|College|Mall|Plaza|Market|Arena|Cathedral|Zoo|Aquarium|Observatory)\M'
        OR e.venue_name ~* '\m(Park|Museum|Library|Center|Centre|Stadium|Field|Gardens|Garden|Hall|Theater|Theatre|Church|School|University|College|Mall|Plaza|Market|Arena|Cathedral|Zoo|Aquarium|Observatory)\M'
        OR e.address ~* '\m(Suite|Ste|Unit|Apt|Floor|Fl|Bldg|Building)\M'
        OR e.address ~* '\m(Gym|Fitness|Studio|Kitchen|Cafe|Restaurant|Bar|Brewery|Winery|Club|Lodge|Pavilion|Amphitheater|Amphitheatre|Pool|Recreation|Rec)\M'
        OR e.venue_name ~* '\m(Gym|Fitness|Studio|Kitchen|Cafe|Restaurant|Bar|Brewery|Winery|Club|Lodge|Pavilion|Amphitheater|Amphitheatre|Pool|Recreation|Rec)\M'
        OR e.venue_name ~ '^\d+\s'
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
