
-- ============================================================================
-- Source: 20260601009600_enrichment_geocodable_address_filter.sql
-- ============================================================================

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


-- ============================================================================
-- Source: 20260601009700_enrichment_geocodable_address_expand.sql
-- ============================================================================

/*
  Expand geocodable-address heuristic to include named places
  -----------------------------------------------------------

  20260601009600 restricted `needs_coords` to rows whose address looks like
  a street address (number prefix or street-type word). That correctly excluded
  libcal room labels but also excluded named places like "Moncus Park" or
  "Lafayette Science Museum" — Nominatim resolves those fine on their own.

  This migration widens the heuristic to also accept place-type words
  (Park, Museum, Center, Library, Stadium, etc.) in either the address or
  venue_name field. Result: ~50-80 more Lafayette events become geocode-
  eligible without re-introducing the libcal room-label noise (room labels
  match "Library" too, but those entries are *always* room labels first —
  acceptable false-positive rate; the cron's attempt-timestamp rotation
  still keeps them from blocking other rows).
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
      -- Geocode-eligible signals, in order of precision:
      --   (a) Street-number prefix ("433 Jefferson St")            — best
      --   (b) Street-type word in address ("101 W Vermilion St")   — good
      --   (c) Place-type word in address OR venue_name             — fair
      --       (Park, Museum, Library, Center, Stadium, Gardens...)
      -- Anything else (raw room labels with no place noun) stays excluded.
      (
        e.address ~ '^\d+\s'
        OR e.address ~* '\m(St|Ave|Blvd|Rd|Dr|Hwy|Pkwy|Way|Ln|Lane|Court|Place|Highway|Parkway|Avenue|Street|Drive|Road|Circle|Cir)\M'
        OR e.address ~* '\m(Park|Museum|Library|Center|Centre|Stadium|Field|Gardens|Garden|Hall|Theater|Theatre|Church|School|University|College|Mall|Plaza|Market|Arena|Cathedral|Zoo|Aquarium|Observatory)\M'
        OR e.venue_name ~* '\m(Park|Museum|Library|Center|Centre|Stadium|Field|Gardens|Garden|Hall|Theater|Theatre|Church|School|University|College|Mall|Plaza|Market|Arena|Cathedral|Zoo|Aquarium|Observatory)\M'
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


-- ============================================================================
-- Source: 20260601009701_index_ai_feature_config_fkeys.sql
-- ============================================================================

-- Add covering indexes for the two unindexed foreign keys on ai_feature_config.
-- Required for efficient referential integrity checks when the referenced rows
-- (approved_ai_models or auth.users) are updated or deleted.

CREATE INDEX IF NOT EXISTS ai_feature_config_model_id_idx
  ON public.ai_feature_config (model_id);

CREATE INDEX IF NOT EXISTS ai_feature_config_updated_by_idx
  ON public.ai_feature_config (updated_by);


-- ============================================================================
-- Source: 20260601009702_parent_tips.sql
-- ============================================================================

/*
  Per-event parent tips
  ---------------------

  Adds AI-generated, per-event "parent tips" (2-3 short actionable
  suggestions for parents bringing kids). Stored as JSONB on events;
  populated by the new generate-parent-tips edge function, claimed
  through list_events_needing_parent_tips, and gated by an
  ai_feature_config row.

  Cold-start: web renders rule-based fallback tips when parent_tips
  IS NULL (apps/web/src/features/events/lib/parent-tips-fallback.ts).
*/

BEGIN;

-- ─── events.parent_tips columns ─────────────────────────────────────────────
ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS parent_tips jsonb,
  ADD COLUMN IF NOT EXISTS parent_tips_generated_at timestamptz,
  ADD COLUMN IF NOT EXISTS parent_tips_provider text,
  ADD COLUMN IF NOT EXISTS parent_tips_model text,
  ADD COLUMN IF NOT EXISTS parent_tips_prompt_version text;

-- Structural CHECK: array of 1-3 elements. Per-element validation
-- (object with non-empty category + text) is enforced by an IMMUTABLE
-- helper because CHECK constraints can't use subqueries directly.
CREATE OR REPLACE FUNCTION private.parent_tips_is_valid(p_tips jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT
    p_tips IS NULL
    OR (
      jsonb_typeof(p_tips) = 'array'
      AND jsonb_array_length(p_tips) BETWEEN 1 AND 3
      AND NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p_tips) AS tip
        WHERE jsonb_typeof(tip) <> 'object'
           OR jsonb_typeof(tip -> 'category') <> 'string'
           OR jsonb_typeof(tip -> 'text') <> 'string'
           OR length(tip ->> 'category') = 0
           OR length(tip ->> 'text') = 0
      )
    );
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'events_parent_tips_shape_chk'
  ) THEN
    ALTER TABLE public.events
      ADD CONSTRAINT events_parent_tips_shape_chk
        CHECK (private.parent_tips_is_valid(parent_tips));
  END IF;
END $$;

-- ─── ai_feature_config: allow 'parent-tips' ─────────────────────────────────
ALTER TABLE public.ai_feature_config
  DROP CONSTRAINT IF EXISTS ai_feature_config_feature_check;

ALTER TABLE public.ai_feature_config
  ADD CONSTRAINT ai_feature_config_feature_check
    CHECK (feature IN ('tagging', 'event-review', 'parent-tips'));

INSERT INTO public.ai_feature_config (feature, model_id, enabled)
VALUES ('parent-tips', 'gpt-4.1-nano', false)
ON CONFLICT (feature) DO NOTHING;

-- ─── upsert_ai_feature_config: allow 'parent-tips' ──────────────────────────
CREATE OR REPLACE FUNCTION private.upsert_ai_feature_config(
  p_feature  text,
  p_model_id text,
  p_enabled  bool
) RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_feature NOT IN ('tagging', 'event-review', 'parent-tips') THEN
    RAISE EXCEPTION 'invalid feature: %', p_feature;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.approved_ai_models
    WHERE id = p_model_id AND is_enabled = true
  ) THEN
    RAISE EXCEPTION 'model % not found or disabled', p_model_id;
  END IF;

  INSERT INTO public.ai_feature_config (feature, model_id, enabled, updated_at, updated_by)
  VALUES (p_feature, p_model_id, p_enabled, now(), auth.uid())
  ON CONFLICT (feature) DO UPDATE SET
    model_id   = EXCLUDED.model_id,
    enabled    = EXCLUDED.enabled,
    updated_at = now(),
    updated_by = auth.uid();
END;
$$;

-- ─── events_enriched_v2: surface is_outdoor + parent_tips ───────────────────
-- Drop the old shape because RETURNS TABLE additions require it.
DROP FUNCTION IF EXISTS public.events_enriched_v2(
  uuid, text, uuid, uuid[], timestamptz, timestamptz, timestamptz, uuid, int
);

CREATE OR REPLACE FUNCTION public.events_enriched_v2(
  p_city_id               uuid DEFAULT NULL::uuid,
  p_status                text DEFAULT 'published'::text,
  p_user_id               uuid DEFAULT NULL::uuid,
  p_event_ids             uuid[] DEFAULT NULL::uuid[],
  p_date_from             timestamptz DEFAULT NULL::timestamptz,
  p_date_to               timestamptz DEFAULT NULL::timestamptz,
  p_after_start_datetime  timestamptz DEFAULT NULL::timestamptz,
  p_after_id              uuid DEFAULT NULL::uuid,
  p_limit                 int DEFAULT 24
)
RETURNS TABLE (
  id                        uuid,
  title                     text,
  description               text,
  start_datetime            timestamptz,
  end_datetime              timestamptz,
  timezone                  text,
  venue_name                text,
  address                   text,
  city_id                   uuid,
  latitude                  numeric,
  longitude                 numeric,
  age_min                   integer,
  age_max                   integer,
  price                     numeric,
  is_free                   boolean,
  source_url                text,
  source_name               text,
  source_id                 uuid,
  images                    jsonb,
  status                    text,
  ai_confidence             numeric,
  ai_tag_provider           text,
  recurrence_info           jsonb,
  is_featured               boolean,
  is_outdoor                boolean,
  parent_tips               jsonb,
  parent_tips_generated_at  timestamptz,
  view_count                integer,
  search_vector             tsvector,
  created_at                timestamptz,
  updated_at                timestamptz,
  avg_rating                numeric,
  rating_count              integer,
  tags                      jsonb,
  is_favorited              boolean,
  is_in_calendar            boolean
)
LANGUAGE sql
STABLE
SET search_path TO ''
AS $$
  SELECT
    e.id, e.title, e.description, e.start_datetime, e.end_datetime, e.timezone,
    e.venue_name, e.address, e.city_id, e.latitude, e.longitude,
    e.age_min, e.age_max, e.price, e.is_free,
    e.source_url, e.source_name, e.source_id, e.images, e.status,
    e.ai_confidence, e.ai_tag_provider, e.recurrence_info, e.is_featured,
    e.is_outdoor, e.parent_tips, e.parent_tips_generated_at,
    e.view_count,
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
        AND e.status = p_status
        AND (p_city_id IS NULL OR e.city_id = p_city_id)
    )
    AND (
      p_after_start_datetime IS NULL
      OR (e.start_datetime, e.id) > (p_after_start_datetime, p_after_id)
    )
  ORDER BY e.start_datetime ASC, e.id ASC
  LIMIT CASE WHEN p_event_ids IS NULL THEN LEAST(GREATEST(p_limit, 1), 200) ELSE NULL END;
$$;

REVOKE ALL ON FUNCTION public.events_enriched_v2(
  uuid, text, uuid, uuid[], timestamptz, timestamptz, timestamptz, uuid, int
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.events_enriched_v2(
  uuid, text, uuid, uuid[], timestamptz, timestamptz, timestamptz, uuid, int
) TO anon, authenticated, service_role;

-- ─── list_events_needing_parent_tips ────────────────────────────────────────
-- Claim queue: events published, no tips yet, never rejected by LLM review.
-- Ordered by last_enrichment_attempt_at so the queue rotates (same livelock
-- guard as list_events_needing_enrichment in migration 9400).
CREATE OR REPLACE FUNCTION private.list_events_needing_parent_tips(
  p_limit int DEFAULT 10
)
RETURNS TABLE (
  event_id        uuid,
  title           text,
  description     text,
  age_min         integer,
  age_max         integer,
  is_outdoor      boolean,
  venue_name      text,
  start_datetime  timestamptz,
  tags            text[]
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH event_tag_slugs AS (
    SELECT
      et.event_id,
      array_agg(t.slug ORDER BY et.confidence DESC NULLS LAST, t.slug ASC) AS slugs
    FROM public.event_tags et
    JOIN public.tags t ON t.id = et.tag_id
    GROUP BY et.event_id
  )
  SELECT
    e.id,
    e.title,
    e.description,
    e.age_min,
    e.age_max,
    e.is_outdoor,
    e.venue_name,
    e.start_datetime,
    COALESCE(ets.slugs, ARRAY[]::text[]) AS tags
  FROM public.events e
  LEFT JOIN event_tag_slugs ets ON ets.event_id = e.id
  WHERE e.parent_tips IS NULL
    AND e.status = 'published'
    AND (e.llm_review_decision IS NULL OR e.llm_review_decision = 'approve')
  ORDER BY e.last_enrichment_attempt_at ASC NULLS FIRST, e.created_at DESC
  LIMIT GREATEST(1, LEAST(p_limit, 50));
$$;

REVOKE EXECUTE ON FUNCTION private.list_events_needing_parent_tips(int)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.list_events_needing_parent_tips(int)
  TO service_role;

CREATE OR REPLACE FUNCTION public.list_events_needing_parent_tips(
  p_limit int DEFAULT 10
)
RETURNS TABLE (
  event_id        uuid,
  title           text,
  description     text,
  age_min         integer,
  age_max         integer,
  is_outdoor      boolean,
  venue_name      text,
  start_datetime  timestamptz,
  tags            text[]
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT * FROM private.list_events_needing_parent_tips(p_limit);
$$;

REVOKE EXECUTE ON FUNCTION public.list_events_needing_parent_tips(int)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.list_events_needing_parent_tips(int)
  TO service_role;

-- ─── update_event_parent_tips: persist edge-fn output ───────────────────────
CREATE OR REPLACE FUNCTION private.update_event_parent_tips(
  p_event_id       uuid,
  p_tips           jsonb,
  p_provider       text,
  p_model          text,
  p_prompt_version text
)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
  UPDATE public.events
  SET parent_tips                = p_tips,
      parent_tips_generated_at   = now(),
      parent_tips_provider       = p_provider,
      parent_tips_model          = p_model,
      parent_tips_prompt_version = p_prompt_version,
      last_enrichment_attempt_at = now(),
      updated_at                 = now()
  WHERE id = p_event_id;
$$;

REVOKE EXECUTE ON FUNCTION private.update_event_parent_tips(uuid, jsonb, text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.update_event_parent_tips(uuid, jsonb, text, text, text)
  TO service_role;

CREATE OR REPLACE FUNCTION public.update_event_parent_tips(
  p_event_id       uuid,
  p_tips           jsonb,
  p_provider       text,
  p_model          text,
  p_prompt_version text
)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.update_event_parent_tips(p_event_id, p_tips, p_provider, p_model, p_prompt_version);
$$;

REVOKE EXECUTE ON FUNCTION public.update_event_parent_tips(uuid, jsonb, text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.update_event_parent_tips(uuid, jsonb, text, text, text)
  TO service_role;

COMMIT;


-- ============================================================================
-- Source: 20260601009703_admin_events_llm_reviewed_filter.sql
-- ============================================================================

-- Let the admin UI filter "LLM reviewed" by review history instead of the
-- current LLM status. Admin publish/reject decisions intentionally set
-- llm_review_status to not_required so resolved events leave Needs Admin
-- Review, but their preserved llm_reviewed_at/decision still mean they were
-- reviewed.

BEGIN;

DROP FUNCTION IF EXISTS private.admin_events_enriched(
  text,
  uuid,
  boolean,
  text,
  timestamptz,
  uuid,
  int,
  public.llm_event_review_status,
  public.llm_event_review_decision
);

DROP FUNCTION IF EXISTS public.admin_events_enriched(
  text,
  uuid,
  boolean,
  text,
  timestamptz,
  uuid,
  int,
  public.llm_event_review_status,
  public.llm_event_review_decision
);

CREATE OR REPLACE FUNCTION private.admin_events_enriched(
  p_status               text                              DEFAULT NULL::text,
  p_city_id              uuid                              DEFAULT NULL::uuid,
  p_city_is_null         boolean                           DEFAULT NULL::boolean,
  p_keyword              text                              DEFAULT NULL::text,
  p_after_created_at     timestamptz                       DEFAULT NULL::timestamptz,
  p_after_id             uuid                              DEFAULT NULL::uuid,
  p_limit                int                               DEFAULT 50,
  p_llm_review_status    public.llm_event_review_status    DEFAULT NULL::public.llm_event_review_status,
  p_llm_review_decision  public.llm_event_review_decision  DEFAULT NULL::public.llm_event_review_decision,
  p_llm_reviewed         boolean                           DEFAULT NULL::boolean
)
RETURNS TABLE (
  id                    uuid,
  title                 text,
  description           text,
  start_datetime        timestamptz,
  end_datetime          timestamptz,
  timezone              text,
  venue_name            text,
  address               text,
  city_id               uuid,
  latitude              numeric,
  longitude             numeric,
  age_min               int,
  age_max               int,
  price                 numeric,
  is_free               boolean,
  source_url            text,
  source_name           text,
  source_id             uuid,
  images                jsonb,
  status                text,
  ai_confidence         numeric,
  ai_tag_provider       text,
  recurrence_info       jsonb,
  is_featured           boolean,
  view_count            int,
  search_vector         tsvector,
  admin_locked_fields   text[],
  admin_last_edited_at  timestamptz,
  admin_last_edited_by  uuid,
  created_at            timestamptz,
  updated_at            timestamptz,
  ai_tag_model          text,
  ai_tag_status         text,
  llm_review_status     public.llm_event_review_status,
  llm_review_decision   public.llm_event_review_decision,
  llm_review_confidence numeric(4,3),
  llm_review_reason     text,
  llm_review_flags      text[],
  llm_review_provider   text,
  llm_review_model      text,
  llm_review_prompt_version text,
  llm_reviewed_at       timestamptz,
  llm_review_error      text,
  total_count           bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH search_input AS (
    SELECT
      CASE
        WHEN p_keyword IS NULL OR btrim(p_keyword) = '' OR length(p_keyword) > 100 THEN NULL::text
        ELSE btrim(p_keyword)
      END AS kw,
      CASE
        WHEN p_keyword IS NULL OR btrim(p_keyword) = '' OR length(p_keyword) > 100 THEN NULL::tsquery
        ELSE websearch_to_tsquery('english', btrim(p_keyword))
      END AS tsq,
      CASE
        WHEN p_keyword IS NULL OR btrim(p_keyword) = '' OR length(p_keyword) > 100 THEN NULL::text
        ELSE replace(replace(replace(btrim(p_keyword), '\\', '\\\\'), '%', '\\%'), '_', '\\_')
      END AS escaped_kw,
      LEAST(GREATEST(COALESCE(p_limit, 50), 1), 500) AS page_size
  ),
  base AS (
    SELECT e.*
    FROM public.events e
    CROSS JOIN search_input si
    WHERE
      (p_status IS NULL OR e.status = p_status)
      AND (
        p_city_is_null IS NULL
        OR (p_city_is_null = true  AND e.city_id IS NULL)
        OR (p_city_is_null = false AND e.city_id IS NOT NULL)
      )
      AND (p_city_id IS NULL OR e.city_id = p_city_id)
      AND (p_llm_review_status IS NULL OR e.llm_review_status = p_llm_review_status)
      AND (p_llm_review_decision IS NULL OR e.llm_review_decision = p_llm_review_decision)
      AND (
        p_llm_reviewed IS DISTINCT FROM true
        OR (
          e.llm_reviewed_at IS NOT NULL
          AND e.llm_review_decision IS NOT NULL
          AND e.llm_review_status <> 'failed'::public.llm_event_review_status
        )
      )
      AND (
        si.kw IS NULL
        OR (
          si.tsq IS NOT NULL
          AND numnode(si.tsq) > 0
          AND e.search_vector @@ si.tsq
        )
        OR (
          si.escaped_kw IS NOT NULL
          AND (si.tsq IS NULL OR numnode(si.tsq) = 0 OR length(si.kw) < 3)
          AND (
            e.title ILIKE '%' || si.escaped_kw || '%' ESCAPE '\\'
            OR e.description ILIKE '%' || si.escaped_kw || '%' ESCAPE '\\'
          )
        )
      )
  ),
  base_count AS (
    SELECT COUNT(*)::bigint AS total_count FROM base
  ),
  page AS (
    SELECT b.*, c.total_count
    FROM base b
    CROSS JOIN base_count c
    WHERE (
      p_after_created_at IS NULL
      OR (
        p_after_id IS NULL
        AND b.created_at < p_after_created_at
      )
      OR (
        p_after_id IS NOT NULL
        AND (b.created_at, b.id) < (p_after_created_at, p_after_id)
      )
    )
    ORDER BY b.created_at DESC, b.id DESC
    LIMIT (SELECT page_size FROM search_input)
  )
  SELECT
    p.id, p.title, p.description, p.start_datetime, p.end_datetime, p.timezone,
    p.venue_name, p.address, p.city_id, p.latitude, p.longitude,
    p.age_min, p.age_max, p.price, p.is_free,
    p.source_url, p.source_name, p.source_id, p.images, p.status,
    p.ai_confidence, p.ai_tag_provider, p.recurrence_info, p.is_featured, p.view_count,
    p.search_vector, p.admin_locked_fields, p.admin_last_edited_at, p.admin_last_edited_by,
    p.created_at, p.updated_at, p.ai_tag_model, p.ai_tag_status,
    p.llm_review_status, p.llm_review_decision, p.llm_review_confidence, p.llm_review_reason,
    p.llm_review_flags, p.llm_review_provider, p.llm_review_model, p.llm_review_prompt_version,
    p.llm_reviewed_at, p.llm_review_error,
    p.total_count
  FROM page p;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_events_enriched(
  p_status               text                              DEFAULT NULL::text,
  p_city_id              uuid                              DEFAULT NULL::uuid,
  p_city_is_null         boolean                           DEFAULT NULL::boolean,
  p_keyword              text                              DEFAULT NULL::text,
  p_after_created_at     timestamptz                       DEFAULT NULL::timestamptz,
  p_after_id             uuid                              DEFAULT NULL::uuid,
  p_limit                int                               DEFAULT 50,
  p_llm_review_status    public.llm_event_review_status    DEFAULT NULL::public.llm_event_review_status,
  p_llm_review_decision  public.llm_event_review_decision  DEFAULT NULL::public.llm_event_review_decision,
  p_llm_reviewed         boolean                           DEFAULT NULL::boolean
)
RETURNS TABLE (
  id                    uuid,
  title                 text,
  description           text,
  start_datetime        timestamptz,
  end_datetime          timestamptz,
  timezone              text,
  venue_name            text,
  address               text,
  city_id               uuid,
  latitude              numeric,
  longitude             numeric,
  age_min               int,
  age_max               int,
  price                 numeric,
  is_free               boolean,
  source_url            text,
  source_name           text,
  source_id             uuid,
  images                jsonb,
  status                text,
  ai_confidence         numeric,
  ai_tag_provider       text,
  recurrence_info       jsonb,
  is_featured           boolean,
  view_count            int,
  search_vector         tsvector,
  admin_locked_fields   text[],
  admin_last_edited_at  timestamptz,
  admin_last_edited_by  uuid,
  created_at            timestamptz,
  updated_at            timestamptz,
  ai_tag_model          text,
  ai_tag_status         text,
  llm_review_status     public.llm_event_review_status,
  llm_review_decision   public.llm_event_review_decision,
  llm_review_confidence numeric(4,3),
  llm_review_reason     text,
  llm_review_flags      text[],
  llm_review_provider   text,
  llm_review_model      text,
  llm_review_prompt_version text,
  llm_reviewed_at       timestamptz,
  llm_review_error      text,
  total_count           bigint
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT * FROM private.admin_events_enriched(
    p_status,
    p_city_id,
    p_city_is_null,
    p_keyword,
    p_after_created_at,
    p_after_id,
    p_limit,
    p_llm_review_status,
    p_llm_review_decision,
    p_llm_reviewed
  );
$$;

REVOKE EXECUTE ON FUNCTION private.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int, public.llm_event_review_status, public.llm_event_review_decision, boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int, public.llm_event_review_status, public.llm_event_review_decision, boolean)
  TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int, public.llm_event_review_status, public.llm_event_review_decision, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int, public.llm_event_review_status, public.llm_event_review_decision, boolean)
  TO authenticated;

COMMIT;


-- ============================================================================
-- Source: 20260601009704_unsplash_attribution_tracking.sql
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.event_image_attributions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  image_url text NOT NULL,
  provider text NOT NULL DEFAULT 'unsplash' CHECK (provider = 'unsplash'),
  matched_tag text,
  unsplash_photo_id text NOT NULL,
  unsplash_photographer_name text NOT NULL,
  unsplash_photographer_username text NOT NULL,
  unsplash_photographer_profile_url text NOT NULL,
  unsplash_photo_url text NOT NULL,
  unsplash_download_location text NOT NULL,
  download_tracked_at timestamptz,
  download_tracking_status text NOT NULL DEFAULT 'pending' CHECK (download_tracking_status IN ('pending', 'succeeded', 'failed')),
  download_tracking_attempts integer NOT NULL DEFAULT 0 CHECK (download_tracking_attempts >= 0),
  download_tracking_last_error text,
  download_tracking_next_attempt_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT event_image_attributions_unique_image UNIQUE (event_id, image_url)
);

CREATE INDEX IF NOT EXISTS event_image_attributions_event_id_idx
  ON public.event_image_attributions(event_id);
CREATE INDEX IF NOT EXISTS event_image_attributions_pending_tracking_idx
  ON public.event_image_attributions(download_tracking_next_attempt_at, created_at)
  WHERE provider = 'unsplash' AND download_tracking_status IN ('pending', 'failed') AND download_tracked_at IS NULL;

ALTER TABLE public.event_image_attributions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS event_image_attributions_no_client_access ON public.event_image_attributions;
CREATE POLICY event_image_attributions_no_client_access
  ON public.event_image_attributions
  FOR ALL
  TO anon, authenticated
  USING (false)
  WITH CHECK (false);

REVOKE ALL ON TABLE public.event_image_attributions FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.event_image_attributions TO service_role;

CREATE OR REPLACE FUNCTION private.touch_event_image_attributions_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS event_image_attributions_touch_updated_at ON public.event_image_attributions;
CREATE TRIGGER event_image_attributions_touch_updated_at
BEFORE UPDATE ON public.event_image_attributions
FOR EACH ROW
EXECUTE FUNCTION private.touch_event_image_attributions_updated_at();

REVOKE EXECUTE ON FUNCTION private.touch_event_image_attributions_updated_at() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.touch_event_image_attributions_updated_at() TO service_role;

CREATE OR REPLACE FUNCTION private.upsert_event_image_attribution_with_enrichment(
  p_event_id uuid,
  p_latitude numeric,
  p_longitude numeric,
  p_images jsonb,
  p_image_url text,
  p_unsplash_photo_id text,
  p_unsplash_photographer_name text,
  p_unsplash_photographer_username text,
  p_unsplash_photographer_profile_url text,
  p_unsplash_photo_url text,
  p_unsplash_download_location text,
  p_matched_tag text DEFAULT NULL::text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_attribution_id uuid;
  v_images_locked boolean;
  v_has_image boolean;
BEGIN
  SELECT 'images' = ANY(e.admin_locked_fields)
  INTO v_images_locked
  FROM public.events e
  WHERE e.id = p_event_id;

  IF v_images_locked IS NULL THEN
    RAISE EXCEPTION 'event % not found', p_event_id USING ERRCODE = 'P0002';
  END IF;

  PERFORM private.update_event_enrichment(p_event_id, p_latitude, p_longitude, p_images);

  v_has_image := p_images IS NOT NULL
    AND jsonb_typeof(p_images) = 'array'
    AND p_image_url IS NOT NULL
    AND p_images ? p_image_url;

  IF v_images_locked OR NOT v_has_image THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.event_image_attributions (
    event_id,
    image_url,
    provider,
    matched_tag,
    unsplash_photo_id,
    unsplash_photographer_name,
    unsplash_photographer_username,
    unsplash_photographer_profile_url,
    unsplash_photo_url,
    unsplash_download_location,
    download_tracking_status,
    download_tracking_next_attempt_at
  ) VALUES (
    p_event_id,
    p_image_url,
    'unsplash',
    p_matched_tag,
    p_unsplash_photo_id,
    p_unsplash_photographer_name,
    p_unsplash_photographer_username,
    p_unsplash_photographer_profile_url,
    p_unsplash_photo_url,
    p_unsplash_download_location,
    'pending',
    now()
  )
  ON CONFLICT (event_id, image_url) DO UPDATE SET
    matched_tag = EXCLUDED.matched_tag,
    unsplash_photo_id = EXCLUDED.unsplash_photo_id,
    unsplash_photographer_name = EXCLUDED.unsplash_photographer_name,
    unsplash_photographer_username = EXCLUDED.unsplash_photographer_username,
    unsplash_photographer_profile_url = EXCLUDED.unsplash_photographer_profile_url,
    unsplash_photo_url = EXCLUDED.unsplash_photo_url,
    unsplash_download_location = EXCLUDED.unsplash_download_location,
    download_tracking_status = CASE
      WHEN public.event_image_attributions.download_tracked_at IS NULL THEN 'pending'
      ELSE public.event_image_attributions.download_tracking_status
    END,
    download_tracking_next_attempt_at = CASE
      WHEN public.event_image_attributions.download_tracked_at IS NULL THEN now()
      ELSE public.event_image_attributions.download_tracking_next_attempt_at
    END
  RETURNING id INTO v_attribution_id;

  RETURN v_attribution_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION private.upsert_event_image_attribution_with_enrichment(
  uuid, numeric, numeric, jsonb, text, text, text, text, text, text, text, text
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.upsert_event_image_attribution_with_enrichment(
  uuid, numeric, numeric, jsonb, text, text, text, text, text, text, text, text
) TO service_role;

CREATE OR REPLACE FUNCTION public.upsert_event_image_attribution_with_enrichment(
  p_event_id uuid,
  p_latitude numeric,
  p_longitude numeric,
  p_images jsonb,
  p_image_url text,
  p_unsplash_photo_id text,
  p_unsplash_photographer_name text,
  p_unsplash_photographer_username text,
  p_unsplash_photographer_profile_url text,
  p_unsplash_photo_url text,
  p_unsplash_download_location text,
  p_matched_tag text DEFAULT NULL::text
)
RETURNS uuid
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.upsert_event_image_attribution_with_enrichment(
    p_event_id,
    p_latitude,
    p_longitude,
    p_images,
    p_image_url,
    p_unsplash_photo_id,
    p_unsplash_photographer_name,
    p_unsplash_photographer_username,
    p_unsplash_photographer_profile_url,
    p_unsplash_photo_url,
    p_unsplash_download_location,
    p_matched_tag
  );
$$;

REVOKE EXECUTE ON FUNCTION public.upsert_event_image_attribution_with_enrichment(
  uuid, numeric, numeric, jsonb, text, text, text, text, text, text, text, text
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_event_image_attribution_with_enrichment(
  uuid, numeric, numeric, jsonb, text, text, text, text, text, text, text, text
) TO service_role;

CREATE OR REPLACE FUNCTION private.list_pending_unsplash_download_tracking(p_limit int DEFAULT 25)
RETURNS TABLE (
  attribution_id uuid,
  event_id uuid,
  image_url text,
  download_location text,
  attempts integer
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    a.id AS attribution_id,
    a.event_id,
    a.image_url,
    a.unsplash_download_location AS download_location,
    a.download_tracking_attempts AS attempts
  FROM public.event_image_attributions a
  WHERE a.provider = 'unsplash'
    AND a.download_tracked_at IS NULL
    AND a.download_tracking_status IN ('pending', 'failed')
    AND a.download_tracking_next_attempt_at <= now()
  ORDER BY a.download_tracking_next_attempt_at ASC, a.created_at ASC
  LIMIT LEAST(GREATEST(p_limit, 1), 100);
$$;

REVOKE EXECUTE ON FUNCTION private.list_pending_unsplash_download_tracking(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.list_pending_unsplash_download_tracking(int) TO service_role;

CREATE OR REPLACE FUNCTION public.list_pending_unsplash_download_tracking(p_limit int DEFAULT 25)
RETURNS TABLE (
  attribution_id uuid,
  event_id uuid,
  image_url text,
  download_location text,
  attempts integer
)
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT * FROM private.list_pending_unsplash_download_tracking(p_limit);
$$;

REVOKE EXECUTE ON FUNCTION public.list_pending_unsplash_download_tracking(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_pending_unsplash_download_tracking(int) TO service_role;

CREATE OR REPLACE FUNCTION private.mark_unsplash_download_tracking_result(
  p_attribution_id uuid,
  p_success boolean,
  p_error text DEFAULT NULL::text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.event_image_attributions a
  SET
    download_tracking_attempts = a.download_tracking_attempts + 1,
    download_tracking_status = CASE WHEN p_success THEN 'succeeded' ELSE 'failed' END,
    download_tracked_at = CASE WHEN p_success THEN now() ELSE a.download_tracked_at END,
    download_tracking_last_error = CASE WHEN p_success THEN NULL ELSE NULLIF(left(COALESCE(p_error, 'unknown error'), 1000), '') END,
    download_tracking_next_attempt_at = CASE
      WHEN p_success THEN a.download_tracking_next_attempt_at
      ELSE now() + make_interval(mins => LEAST(1440, GREATEST(5, (a.download_tracking_attempts + 1) * 15)))
    END
  WHERE a.id = p_attribution_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'attribution % not found', p_attribution_id USING ERRCODE = 'P0002';
  END IF;
END;
$$;

REVOKE EXECUTE ON FUNCTION private.mark_unsplash_download_tracking_result(uuid, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.mark_unsplash_download_tracking_result(uuid, boolean, text) TO service_role;

CREATE OR REPLACE FUNCTION public.mark_unsplash_download_tracking_result(
  p_attribution_id uuid,
  p_success boolean,
  p_error text DEFAULT NULL::text
)
RETURNS void
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.mark_unsplash_download_tracking_result(p_attribution_id, p_success, p_error);
$$;

REVOKE EXECUTE ON FUNCTION public.mark_unsplash_download_tracking_result(uuid, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_unsplash_download_tracking_result(uuid, boolean, text) TO service_role;

CREATE OR REPLACE FUNCTION private.public_event_image_attributions(p_event_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'provider', a.provider,
        'image_url', a.image_url,
        'matched_tag', a.matched_tag,
        'photo_id', a.unsplash_photo_id,
        'photographer_name', a.unsplash_photographer_name,
        'photographer_username', a.unsplash_photographer_username,
        'photographer_profile_url', a.unsplash_photographer_profile_url,
        'photo_url', a.unsplash_photo_url
      )
      ORDER BY a.created_at ASC
    ),
    '[]'::jsonb
  )
  FROM public.event_image_attributions a
  WHERE a.event_id = p_event_id;
$$;

REVOKE EXECUTE ON FUNCTION private.public_event_image_attributions(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.public_event_image_attributions(uuid) TO anon, authenticated, service_role;

DROP FUNCTION IF EXISTS public.events_enriched_v2(
  uuid, text, uuid, uuid[], timestamptz, timestamptz, timestamptz, uuid, int
);

CREATE OR REPLACE FUNCTION public.events_enriched_v2(
  p_city_id               uuid DEFAULT NULL::uuid,
  p_status                text DEFAULT 'published'::text,
  p_user_id               uuid DEFAULT NULL::uuid,
  p_event_ids             uuid[] DEFAULT NULL::uuid[],
  p_date_from             timestamptz DEFAULT NULL::timestamptz,
  p_date_to               timestamptz DEFAULT NULL::timestamptz,
  p_after_start_datetime  timestamptz DEFAULT NULL::timestamptz,
  p_after_id              uuid DEFAULT NULL::uuid,
  p_limit                 int DEFAULT 24
)
RETURNS TABLE (
  id                        uuid,
  title                     text,
  description               text,
  start_datetime            timestamptz,
  end_datetime              timestamptz,
  timezone                  text,
  venue_name                text,
  address                   text,
  city_id                   uuid,
  latitude                  numeric,
  longitude                 numeric,
  age_min                   integer,
  age_max                   integer,
  price                     numeric,
  is_free                   boolean,
  source_url                text,
  source_name               text,
  source_id                 uuid,
  images                    jsonb,
  status                    text,
  ai_confidence             numeric,
  ai_tag_provider           text,
  recurrence_info           jsonb,
  is_featured               boolean,
  is_outdoor                boolean,
  parent_tips               jsonb,
  parent_tips_generated_at  timestamptz,
  view_count                integer,
  search_vector             tsvector,
  created_at                timestamptz,
  updated_at                timestamptz,
  avg_rating                numeric,
  rating_count              integer,
  tags                      jsonb,
  image_attributions        jsonb,
  is_favorited              boolean,
  is_in_calendar            boolean
)
LANGUAGE sql
STABLE
SET search_path TO ''
AS $$
  SELECT
    e.id, e.title, e.description, e.start_datetime, e.end_datetime, e.timezone,
    e.venue_name, e.address, e.city_id, e.latitude, e.longitude,
    e.age_min, e.age_max, e.price, e.is_free,
    e.source_url, e.source_name, e.source_id, e.images, e.status,
    e.ai_confidence, e.ai_tag_provider, e.recurrence_info, e.is_featured,
    e.is_outdoor, e.parent_tips, e.parent_tips_generated_at,
    e.view_count,
    e.search_vector, e.created_at, e.updated_at,
    COALESCE(rs.avg_score, 0)::numeric    AS avg_rating,
    COALESCE(rs.rating_count, 0)::int     AS rating_count,
    COALESCE(ts.tags, '[]'::jsonb)        AS tags,
    private.public_event_image_attributions(e.id) AS image_attributions,
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
        AND e.status = p_status
        AND (p_city_id IS NULL OR e.city_id = p_city_id)
    )
    AND (
      p_after_start_datetime IS NULL
      OR (e.start_datetime, e.id) > (p_after_start_datetime, p_after_id)
    )
  ORDER BY e.start_datetime ASC, e.id ASC
  LIMIT CASE WHEN p_event_ids IS NULL THEN LEAST(GREATEST(p_limit, 1), 200) ELSE NULL END;
$$;

REVOKE ALL ON FUNCTION public.events_enriched_v2(
  uuid, text, uuid, uuid[], timestamptz, timestamptz, timestamptz, uuid, int
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.events_enriched_v2(
  uuid, text, uuid, uuid[], timestamptz, timestamptz, timestamptz, uuid, int
) TO anon, authenticated, service_role;

COMMIT;


-- ============================================================================
-- Source: 20260601009706_attribution_backfill_fn.sql
-- ============================================================================

BEGIN;

-- Returns events that have an Unsplash CDN image stored but no attribution row.
-- Used by the backfill-event-enrichment edge function attribution pass.
CREATE OR REPLACE FUNCTION private.list_events_needing_attribution_backfill(p_limit int DEFAULT 10)
RETURNS TABLE (
  event_id uuid,
  image_url text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    e.id AS event_id,
    (e.images->>0) AS image_url
  FROM public.events e
  WHERE e.status = 'published'
    AND e.images IS NOT NULL
    AND jsonb_typeof(e.images) = 'array'
    AND jsonb_array_length(e.images) > 0
    AND (e.images->>0) ILIKE '%images.unsplash.com/%'
    AND NOT EXISTS (
      SELECT 1 FROM public.event_image_attributions a WHERE a.event_id = e.id
    )
  ORDER BY e.created_at ASC
  LIMIT LEAST(GREATEST(p_limit, 1), 50);
$$;

REVOKE EXECUTE ON FUNCTION private.list_events_needing_attribution_backfill(int)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.list_events_needing_attribution_backfill(int)
  TO service_role;

CREATE OR REPLACE FUNCTION public.list_events_needing_attribution_backfill(p_limit int DEFAULT 10)
RETURNS TABLE (
  event_id uuid,
  image_url text
)
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT * FROM private.list_events_needing_attribution_backfill(p_limit);
$$;

REVOKE EXECUTE ON FUNCTION public.list_events_needing_attribution_backfill(int)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_events_needing_attribution_backfill(int)
  TO service_role;

COMMIT;


-- ============================================================================
-- Source: 20260601009707_raise_events_enriched_v2_limit.sql
-- ============================================================================

BEGIN;

-- Raise per-call cap from 200 → 500 to support calendar month queries.
-- A busy month can have 200+ published events; the old cap silently truncated
-- results ordered start_datetime ASC, making recent/future dates invisible.
CREATE OR REPLACE FUNCTION public.events_enriched_v2(
  p_city_id               uuid DEFAULT NULL::uuid,
  p_status                text DEFAULT 'published'::text,
  p_user_id               uuid DEFAULT NULL::uuid,
  p_event_ids             uuid[] DEFAULT NULL::uuid[],
  p_date_from             timestamptz DEFAULT NULL::timestamptz,
  p_date_to               timestamptz DEFAULT NULL::timestamptz,
  p_after_start_datetime  timestamptz DEFAULT NULL::timestamptz,
  p_after_id              uuid DEFAULT NULL::uuid,
  p_limit                 int DEFAULT 24
)
RETURNS TABLE (
  id                        uuid,
  title                     text,
  description               text,
  start_datetime            timestamptz,
  end_datetime              timestamptz,
  timezone                  text,
  venue_name                text,
  address                   text,
  city_id                   uuid,
  latitude                  numeric,
  longitude                 numeric,
  age_min                   integer,
  age_max                   integer,
  price                     numeric,
  is_free                   boolean,
  source_url                text,
  source_name               text,
  source_id                 uuid,
  images                    jsonb,
  status                    text,
  ai_confidence             numeric,
  ai_tag_provider           text,
  recurrence_info           jsonb,
  is_featured               boolean,
  is_outdoor                boolean,
  parent_tips               jsonb,
  parent_tips_generated_at  timestamptz,
  view_count                integer,
  search_vector             tsvector,
  created_at                timestamptz,
  updated_at                timestamptz,
  avg_rating                numeric,
  rating_count              integer,
  tags                      jsonb,
  image_attributions        jsonb,
  is_favorited              boolean,
  is_in_calendar            boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $$
  SELECT
    e.id, e.title, e.description, e.start_datetime, e.end_datetime, e.timezone,
    e.venue_name, e.address, e.city_id, e.latitude, e.longitude,
    e.age_min, e.age_max, e.price, e.is_free,
    e.source_url, e.source_name, e.source_id, e.images, e.status,
    e.ai_confidence, e.ai_tag_provider, e.recurrence_info, e.is_featured,
    e.is_outdoor, e.parent_tips, e.parent_tips_generated_at,
    e.view_count,
    e.search_vector, e.created_at, e.updated_at,
    COALESCE(rs.avg_score, 0)::numeric    AS avg_rating,
    COALESCE(rs.rating_count, 0)::int     AS rating_count,
    COALESCE(ts.tags, '[]'::jsonb)        AS tags,
    COALESCE(ias.image_attributions, '[]'::jsonb) AS image_attributions,
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
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(
             jsonb_build_object(
               'provider', a.provider,
               'image_url', a.image_url,
               'matched_tag', a.matched_tag,
               'photo_id', a.unsplash_photo_id,
               'photographer_name', a.unsplash_photographer_name,
               'photographer_username', a.unsplash_photographer_username,
               'photographer_profile_url', a.unsplash_photographer_profile_url,
               'photo_url', a.unsplash_photo_url
             )
             ORDER BY a.created_at ASC
           ) AS image_attributions
    FROM public.event_image_attributions a
    WHERE a.event_id = e.id
  ) ias ON TRUE
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
        AND e.status = p_status
        AND (p_city_id IS NULL OR e.city_id = p_city_id)
    )
    AND (
      p_after_start_datetime IS NULL
      OR (e.start_datetime, e.id) > (p_after_start_datetime, p_after_id)
    )
  ORDER BY e.start_datetime ASC, e.id ASC
  LIMIT CASE WHEN p_event_ids IS NULL THEN LEAST(GREATEST(p_limit, 1), 500) ELSE NULL END;
$$;

REVOKE ALL ON FUNCTION public.events_enriched_v2(
  uuid, text, uuid, uuid[], timestamptz, timestamptz, timestamptz, uuid, int
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.events_enriched_v2(
  uuid, text, uuid, uuid[], timestamptz, timestamptz, timestamptz, uuid, int
) TO anon, authenticated, service_role;

COMMIT;


-- ============================================================================
-- Source: 20260601009708_index_event_llm_review_fkeys.sql
-- ============================================================================

-- Supabase performance advisors require plain covering indexes for foreign-key
-- columns. The existing partial indexes on nullable source/queue columns are
-- good for app reads, but the FK advisor does not count them as covering
-- indexes for referential actions.

DROP INDEX IF EXISTS public.event_llm_review_queue_source_id_idx;
DROP INDEX IF EXISTS public.event_llm_review_queue_source_run_id_idx;
DROP INDEX IF EXISTS public.event_llm_review_traces_queue_id_idx;
DROP INDEX IF EXISTS public.event_llm_review_traces_source_id_idx;
DROP INDEX IF EXISTS public.event_llm_review_traces_source_run_id_idx;

CREATE INDEX IF NOT EXISTS event_llm_review_queue_source_id_idx
  ON public.event_llm_review_queue USING btree (source_id);

CREATE INDEX IF NOT EXISTS event_llm_review_queue_source_run_id_idx
  ON public.event_llm_review_queue USING btree (source_run_id);

CREATE INDEX IF NOT EXISTS event_llm_review_traces_queue_id_idx
  ON public.event_llm_review_traces USING btree (queue_id);

CREATE INDEX IF NOT EXISTS event_llm_review_traces_source_id_idx
  ON public.event_llm_review_traces USING btree (source_id);

CREATE INDEX IF NOT EXISTS event_llm_review_traces_source_run_id_idx
  ON public.event_llm_review_traces USING btree (source_run_id);


-- ============================================================================
-- Source: 20260601009709_restrict_pg_timezone_names.sql
-- ============================================================================

BEGIN;

CREATE OR REPLACE VIEW public.pg_timezone_names
WITH (security_invoker = true) AS
SELECT name
FROM private.timezone_names_cache;

COMMENT ON VIEW public.pg_timezone_names IS
  'Compatibility view for clients that query pg_timezone_names through the Data API. Reads private.timezone_names_cache instead of the slow pg_catalog.pg_timezone_names function scan.';

GRANT SELECT ON TABLE public.pg_timezone_names TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;


-- ============================================================================
-- Source: 20260601009800_enrichment_geocodable_address_expand_2.sql
-- ============================================================================

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


-- ============================================================================
-- Source: 20260601009900_drop_search_events_rpc.sql
-- ============================================================================

-- Drop the legacy search_events RPC (v1).
-- This function has zero callers in apps/web/src, zero edge function callers,
-- and is superseded by search_events_v2 (cursor-based pagination).
-- See DECISIONS.md D004 for rationale.

BEGIN;

REVOKE ALL ON FUNCTION public.search_events FROM anon, authenticated;

DROP FUNCTION IF EXISTS public.search_events(
  p_city_id   uuid,
  p_date_from timestamptz,
  p_date_to   timestamptz,
  p_age_min   int,
  p_age_max   int,
  p_is_free   boolean,
  p_is_featured boolean,
  p_tag_slugs text[],
  p_keyword   text,
  p_status    text,
  p_limit     int,
  p_offset    int
);

COMMIT;


-- ============================================================================
-- Source: 20260601009901_enrichment_geocodable_address_building_types.sql
-- ============================================================================

/*
  Expand geocodable-address heuristic — round 3 (009901)
  -------------------------------------------------------

  Baselines:
    009700 — introduced place-type words (Park, Museum, Library, etc.) in
             address/venue_name clauses (c)/(d).
    009800 — added suite/unit indicators, extended venue types, and
             venue_name street-number prefix; clauses (d)–(g).

  This migration extends clauses (c) and (d) with six additional place-type
  words that represent common event venues missed by prior rounds:

    Building   — e.g. "Memorial Building", "Roberts Building"
    Complex    — e.g. "Sports Complex", "Civic Complex"
    Facility   — e.g. "Recreation Facility", "Community Facility"
    Auditorium — e.g. "Heymann Auditorium", "Municipal Auditorium"
    Convention — e.g. "Convention Center", "Convention Hall"
    Conference — e.g. "Conference Center", "Hilton Conference"

  Note: "Building" already appears in clause (e) (suite/unit indicators:
  Suite|Ste|Unit|Apt|Floor|Fl|Bldg|Building) so address matches are already
  caught. Adding it to clause (c) is harmless (short-circuits earlier) and
  makes the intent of the place-type list explicit.

  No other clauses are modified.  All structure, security model, and
  search_path settings are identical to 009800.

  Reference: 009800, 009700, 009600.
*/

-- DIAGNOSTIC QUERY ----------------------------------------------------------
-- Run these before/after to measure impact on local seed data.
--
-- Newly-eligible count added by 009901 patterns:
--
--    SELECT count(*) AS newly_eligible_009901
--    FROM public.events e
--    WHERE
--      -- not already eligible via 009700/009800 baselines:
--      NOT (
--        e.address ~ '^\d+\s'
--        OR e.address ~* '\m(St|Ave|Blvd|Rd|Dr|Hwy|Pkwy|Way|Ln|Lane|Court|Place|Highway|Parkway|Avenue|Street|Drive|Road|Circle|Cir)\M'
--        OR e.address ~* '\m(Park|Museum|Library|Center|Centre|Stadium|Field|Gardens|Garden|Hall|Theater|Theatre|Church|School|University|College|Mall|Plaza|Market|Arena|Cathedral|Zoo|Aquarium|Observatory)\M'
--        OR e.venue_name ~* '\m(Park|Museum|Library|Center|Centre|Stadium|Field|Gardens|Garden|Hall|Theater|Theatre|Church|School|University|College|Mall|Plaza|Market|Arena|Cathedral|Zoo|Aquarium|Observatory)\M'
--        OR e.address ~* '\m(Suite|Ste|Unit|Apt|Floor|Fl|Bldg|Building)\M'
--        OR e.address ~* '\m(Gym|Fitness|Studio|Kitchen|Cafe|Restaurant|Bar|Brewery|Winery|Club|Lodge|Pavilion|Amphitheater|Amphitheatre|Pool|Recreation|Rec)\M'
--        OR e.venue_name ~* '\m(Gym|Fitness|Studio|Kitchen|Cafe|Restaurant|Bar|Brewery|Winery|Club|Lodge|Pavilion|Amphitheater|Amphitheatre|Pool|Recreation|Rec)\M'
--        OR e.venue_name ~ '^\d+\s'
--      )
--      -- newly eligible via 009901:
--      AND (
--        e.address ~* '\m(Building|Complex|Facility|Auditorium|Convention|Conference)\M'
--        OR e.venue_name ~* '\m(Building|Complex|Facility|Auditorium|Convention|Conference)\M'
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
      --   (c) Place-type word in address                           — fair
      --       (Park, Museum, Library, Center, Stadium, Gardens...
      --        + Building, Complex, Facility, Auditorium,
      --          Convention, Conference  [added 009901])
      --   (d) Same place-type set in venue_name                    — fair
      --   (e) Suite/unit indicators in address                     — good
      --       (Suite, Ste, Unit, Apt, Floor, Fl, Bldg, Building)
      --   (f) Extended venue place-types in address                — fair
      --       (Gym, Fitness, Studio, Kitchen, Cafe, Restaurant, ...)
      --   (g) Extended venue place-types in venue_name             — fair
      --   (h) venue_name starts with a street number               — good
      -- Anything else (raw room labels with no place noun) stays excluded.
      (
        e.address ~ '^\d+\s'
        OR e.address ~* '\m(St|Ave|Blvd|Rd|Dr|Hwy|Pkwy|Way|Ln|Lane|Court|Place|Highway|Parkway|Avenue|Street|Drive|Road|Circle|Cir)\M'
        OR e.address ~* '\m(Park|Museum|Library|Center|Centre|Stadium|Field|Gardens|Garden|Hall|Theater|Theatre|Church|School|University|College|Mall|Plaza|Market|Arena|Cathedral|Zoo|Aquarium|Observatory|Building|Complex|Facility|Auditorium|Convention|Conference)\M'
        OR e.venue_name ~* '\m(Park|Museum|Library|Center|Centre|Stadium|Field|Gardens|Garden|Hall|Theater|Theatre|Church|School|University|College|Mall|Plaza|Market|Arena|Cathedral|Zoo|Aquarium|Observatory|Building|Complex|Facility|Auditorium|Convention|Conference)\M'
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


-- ============================================================================
-- Source: 20260601009902_rename_v2_rpcs_to_canonical.sql
-- ============================================================================

/*
  Rename _v2 RPCs to canonical unversioned names (009902)
  --------------------------------------------------------

  events_enriched_v2 → events_enriched   (consumer event fetch)
  search_events_v2   → search_events     (keyword search, used in tests/admin)

  The old v1 events_enriched was already superseded by v2; we now make v2
  the single canonical function. The old search_events v1 was already
  dropped in migration 009900. This migration completes the cleanup.

  All callers updated in the same commit:
    - apps/web/src/lib/db/rpc-events.ts
    - apps/web/src/features/plan/hooks/use-plan-for-today.ts
    - apps/ios/Packages/FEData/Sources/FEData/Repositories/EventRepository.swift
    - packages/contracts/src/database.types.ts
    - supabase/tests/role_smoke.sql
    - supabase/tests/events_cursor_pagination.sql
*/

BEGIN;

-- ============================================================
-- 0. Drop the old v1 events_enriched (offset-based, pre-cursor)
--    so we can recreate it with the v2 signature cleanly.
-- ============================================================
DROP FUNCTION IF EXISTS public.events_enriched(
  uuid, text, integer, integer, uuid, uuid[], timestamptz, timestamptz
);

-- ============================================================
-- 1. Recreate events_enriched_v2 body under the canonical name
-- ============================================================
CREATE OR REPLACE FUNCTION public.events_enriched(
  p_city_id               uuid DEFAULT NULL::uuid,
  p_status                text DEFAULT 'published'::text,
  p_user_id               uuid DEFAULT NULL::uuid,
  p_event_ids             uuid[] DEFAULT NULL::uuid[],
  p_date_from             timestamptz DEFAULT NULL::timestamptz,
  p_date_to               timestamptz DEFAULT NULL::timestamptz,
  p_after_start_datetime  timestamptz DEFAULT NULL::timestamptz,
  p_after_id              uuid DEFAULT NULL::uuid,
  p_limit                 int DEFAULT 24
)
RETURNS TABLE (
  id                        uuid,
  title                     text,
  description               text,
  start_datetime            timestamptz,
  end_datetime              timestamptz,
  timezone                  text,
  venue_name                text,
  address                   text,
  city_id                   uuid,
  latitude                  numeric,
  longitude                 numeric,
  age_min                   integer,
  age_max                   integer,
  price                     numeric,
  is_free                   boolean,
  source_url                text,
  source_name               text,
  source_id                 uuid,
  images                    jsonb,
  status                    text,
  ai_confidence             numeric,
  ai_tag_provider           text,
  recurrence_info           jsonb,
  is_featured               boolean,
  is_outdoor                boolean,
  parent_tips               jsonb,
  parent_tips_generated_at  timestamptz,
  view_count                integer,
  search_vector             tsvector,
  created_at                timestamptz,
  updated_at                timestamptz,
  avg_rating                numeric,
  rating_count              integer,
  tags                      jsonb,
  image_attributions        jsonb,
  is_favorited              boolean,
  is_in_calendar            boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $$
  SELECT
    e.id, e.title, e.description, e.start_datetime, e.end_datetime, e.timezone,
    e.venue_name, e.address, e.city_id, e.latitude, e.longitude,
    e.age_min, e.age_max, e.price, e.is_free,
    e.source_url, e.source_name, e.source_id, e.images, e.status,
    e.ai_confidence, e.ai_tag_provider, e.recurrence_info, e.is_featured,
    e.is_outdoor, e.parent_tips, e.parent_tips_generated_at,
    e.view_count,
    e.search_vector, e.created_at, e.updated_at,
    COALESCE(rs.avg_score, 0)::numeric    AS avg_rating,
    COALESCE(rs.rating_count, 0)::int     AS rating_count,
    COALESCE(ts.tags, '[]'::jsonb)        AS tags,
    COALESCE(ias.image_attributions, '[]'::jsonb) AS image_attributions,
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
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(
             jsonb_build_object(
               'provider', a.provider,
               'image_url', a.image_url,
               'matched_tag', a.matched_tag,
               'photo_id', a.unsplash_photo_id,
               'photographer_name', a.unsplash_photographer_name,
               'photographer_username', a.unsplash_photographer_username,
               'photographer_profile_url', a.unsplash_photographer_profile_url,
               'photo_url', a.unsplash_photo_url
             )
             ORDER BY a.created_at ASC
           ) AS image_attributions
    FROM public.event_image_attributions a
    WHERE a.event_id = e.id
  ) ias ON TRUE
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
        AND e.status = p_status
        AND (p_city_id IS NULL OR e.city_id = p_city_id)
    )
    AND (
      p_after_start_datetime IS NULL
      OR (e.start_datetime, e.id) > (p_after_start_datetime, p_after_id)
    )
  ORDER BY e.start_datetime ASC, e.id ASC
  LIMIT CASE WHEN p_event_ids IS NULL THEN LEAST(GREATEST(p_limit, 1), 500) ELSE NULL END;
$$;

REVOKE ALL ON FUNCTION public.events_enriched(
  uuid, text, uuid, uuid[], timestamptz, timestamptz, timestamptz, uuid, int
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.events_enriched(
  uuid, text, uuid, uuid[], timestamptz, timestamptz, timestamptz, uuid, int
) TO anon, authenticated, service_role;

-- ============================================================
-- 2. Drop the _v2 alias now that the canonical name is live
-- ============================================================
DROP FUNCTION IF EXISTS public.events_enriched_v2(
  uuid, text, uuid, uuid[], timestamptz, timestamptz, timestamptz, uuid, int
);

-- ============================================================
-- 3. Rename search_events_v2 → search_events
--    (search_events v1 was already dropped in migration 009900)
-- ============================================================
-- search_events_v2 signature from 007001:
DROP FUNCTION IF EXISTS public.search_events_v2(
  uuid, timestamptz, timestamptz, integer, integer, boolean, boolean,
  text[], text, text, integer, integer, timestamptz, uuid
);

-- Recreate under canonical name (exact body from search_events_v2 in 007001)
CREATE OR REPLACE FUNCTION public.search_events(
  p_city_id               uuid DEFAULT NULL::uuid,
  p_date_from             timestamptz DEFAULT NULL::timestamptz,
  p_date_to               timestamptz DEFAULT NULL::timestamptz,
  p_age_min               integer DEFAULT NULL::integer,
  p_age_max               integer DEFAULT NULL::integer,
  p_is_free               boolean DEFAULT NULL::boolean,
  p_is_featured           boolean DEFAULT NULL::boolean,
  p_tag_slugs             text[] DEFAULT NULL::text[],
  p_keyword               text DEFAULT NULL::text,
  p_status                text DEFAULT 'published'::text,
  p_limit                 integer DEFAULT 100,
  p_offset                integer DEFAULT 0,
  p_after_start_datetime  timestamptz DEFAULT NULL::timestamptz,
  p_after_id              uuid DEFAULT NULL::uuid
)
RETURNS SETOF public.events
LANGUAGE sql
STABLE
SET search_path TO ''
AS $$
  WITH search_input AS (
    SELECT
      CASE
        WHEN p_keyword IS NULL OR btrim(p_keyword) = '' OR length(p_keyword) > 100 THEN NULL::text
        ELSE btrim(p_keyword)
      END AS kw,
      CASE
        WHEN p_keyword IS NULL OR btrim(p_keyword) = '' OR length(p_keyword) > 100 THEN NULL::tsquery
        ELSE websearch_to_tsquery('english', btrim(p_keyword))
      END AS tsq,
      CASE
        WHEN p_keyword IS NULL OR btrim(p_keyword) = '' OR length(p_keyword) > 100 THEN NULL::text
        ELSE replace(replace(replace(btrim(p_keyword), '\', '\\'), '%', '\%'), '_', '\_')
      END AS escaped_kw
  )
  SELECT e.*
  FROM public.events e
  CROSS JOIN search_input si
  WHERE e.status = p_status
    AND (p_city_id IS NULL OR e.city_id = p_city_id)
    AND (p_date_from IS NULL OR e.start_datetime >= p_date_from)
    AND (p_date_to IS NULL OR e.start_datetime <= p_date_to)
    AND (p_is_free IS NULL OR e.is_free = p_is_free)
    AND (p_is_featured IS NULL OR e.is_featured = p_is_featured)
    AND (p_age_min IS NULL OR COALESCE(e.age_max, 99) >= p_age_min)
    AND (p_age_max IS NULL OR COALESCE(e.age_min, 0) <= p_age_max)
    AND (
      si.kw IS NULL
      OR (
        si.tsq IS NOT NULL
        AND numnode(si.tsq) > 0
        AND e.search_vector @@ si.tsq
      )
      OR (
        si.escaped_kw IS NOT NULL
        AND (numnode(si.tsq) = 0 OR length(si.kw) < 3)
        AND (
          e.title ILIKE '%' || si.escaped_kw || '%' ESCAPE '\'
          OR e.description ILIKE '%' || si.escaped_kw || '%' ESCAPE '\'
        )
      )
    )
    AND (
      p_tag_slugs IS NULL
      OR array_length(p_tag_slugs, 1) IS NULL
      OR (
        SELECT COUNT(DISTINCT t.slug)
        FROM public.event_tags et
        JOIN public.tags t ON t.id = et.tag_id
        WHERE et.event_id = e.id AND t.slug = ANY(p_tag_slugs)
      ) = array_length(p_tag_slugs, 1)
    )
    AND (
      p_after_start_datetime IS NULL
      OR (e.start_datetime, e.id) > (p_after_start_datetime, p_after_id)
    )
  ORDER BY
    CASE
      WHEN si.tsq IS NULL OR numnode(si.tsq) = 0 THEN NULL::real
      ELSE ts_rank_cd(e.search_vector, si.tsq)
    END DESC NULLS LAST,
    e.start_datetime ASC,
    e.id ASC
  LIMIT LEAST(GREATEST(p_limit, 0), 500)
  OFFSET GREATEST(p_offset, 0);
$$;

REVOKE ALL ON FUNCTION public.search_events(
  uuid, timestamptz, timestamptz, integer, integer, boolean, boolean,
  text[], text, text, integer, integer, timestamptz, uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.search_events(
  uuid, timestamptz, timestamptz, integer, integer, boolean, boolean,
  text[], text, text, integer, integer, timestamptz, uuid
) TO anon, authenticated, service_role;

COMMIT;

