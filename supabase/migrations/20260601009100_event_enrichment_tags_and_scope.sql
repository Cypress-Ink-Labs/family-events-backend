/*
  Image-fallback enrichment groundwork
  ------------------------------------

  Two related changes that the Unsplash image-fallback work in the
  backfill-event-enrichment edge fn needs:

    1. `private.list_events_needing_enrichment` now returns a
       `tags text[]` column carrying the event's tag slugs ordered by
       confidence DESC. The edge fn uses tags[0] as the Unsplash query
       term. Adding it to the existing RPC is backwards compatible at
       the call site (every existing caller does
       `select * from list_events_needing_enrichment(...)` so the
       extra column is automatically picked up).

    2. New `private.backfill_image_enrichment_in_scope(p_limit)` RPC
       returns the same row shape but narrows to rows where:
         (a) images is empty,
         (b) the row isn't admin-locked on `images`,
         (c) status = 'published',
         (d) either is_featured = true OR start_datetime is within
             [now, now + 30 days].
       This bounds Unsplash API spend to events users will actually see
       in the next month. The existing coords-only flow keeps using
       `list_events_needing_enrichment` so it can still fill geocodes
       on stale rows.

  Both the existing tags column extension and the new scoped RPC are
  invocable only by `service_role`; the `public.*` SECURITY INVOKER
  wrappers exist for PostgREST clients (edge fns) that talk through
  the public schema.
*/

BEGIN;

-- 1) Extend list_events_needing_enrichment with tags text[].
--
-- PG won't allow CREATE OR REPLACE to change a function's RETURNS TABLE
-- shape. Drop both the public wrapper and the private implementation
-- before re-creating with the new column. No views or indexes depend
-- on these RPCs — they're called only from edge functions over
-- PostgREST — so no CASCADE concerns.

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
      ) AS _needs_coords,
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
    ef._needs_coords  AS needs_coords,
    ef._needs_images  AS needs_images,
    ef.admin_locked_fields,
    COALESCE(ets.slugs, ARRAY[]::text[]) AS tags
  FROM enrichment_flags ef
  LEFT JOIN event_tag_slugs ets ON ets.event_id = ef.id
  WHERE ef._needs_coords OR ef._needs_images
  ORDER BY ef.created_at DESC
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

-- 2) backfill_image_enrichment_in_scope — featured OR next 30 days, images-only.

CREATE OR REPLACE FUNCTION private.backfill_image_enrichment_in_scope(p_limit int DEFAULT 25)
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
  WITH scoped AS (
    SELECT e.*
    FROM public.events e
    WHERE e.status = 'published'
      AND (e.images = '[]'::jsonb OR jsonb_array_length(e.images) = 0)
      AND NOT 'images' = ANY(e.admin_locked_fields)
      AND (
        e.is_featured = true
        OR (e.start_datetime BETWEEN now() AND now() + interval '30 days')
      )
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
    s.id,
    s.title,
    s.description,
    s.venue_name,
    s.address,
    s.city_id,
    s.source_id,
    s.source_url,
    false                                                    AS needs_coords,
    true                                                     AS needs_images,
    s.admin_locked_fields,
    COALESCE(ets.slugs, ARRAY[]::text[])                     AS tags
  FROM scoped s
  LEFT JOIN event_tag_slugs ets ON ets.event_id = s.id
  ORDER BY s.is_featured DESC, s.start_datetime ASC
  LIMIT GREATEST(1, LEAST(p_limit, 100));
$$;

REVOKE EXECUTE ON FUNCTION private.backfill_image_enrichment_in_scope(int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.backfill_image_enrichment_in_scope(int) TO service_role;

CREATE OR REPLACE FUNCTION public.backfill_image_enrichment_in_scope(p_limit int DEFAULT 25)
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
  SELECT * FROM private.backfill_image_enrichment_in_scope(p_limit);
$$;

REVOKE EXECUTE ON FUNCTION public.backfill_image_enrichment_in_scope(int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.backfill_image_enrichment_in_scope(int) TO service_role;

COMMIT;
