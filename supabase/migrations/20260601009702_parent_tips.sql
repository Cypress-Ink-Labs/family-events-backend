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
