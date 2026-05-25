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
