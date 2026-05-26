
-- ============================================================================
-- Source: 20260601007000_bulk_import_scrape_events.sql
-- ============================================================================

/*
  # Bulk import RPC for scrape-source

  Replaces the per-event JS loop in processSource (605 events × 2 DB
  round-trips ≈ 150s edge wall blown) with a single SQL transaction.

  Per-event work that stays in JS (still HTTP-bound):
    - Parser/extractor (HTML/RSS/iCal → ParsedEvent[])
    - Geocode for NEW events (Nominatim HTTP)
    - Image HEAD validation (HTTP)
    - Source URL is the sole dedup key (UNIQUE index on source_id + source_url)

  Per-event work that moves to SQL:
    - Lookup existing by (source_id, source_url) via UNIQUE partial index
    - Classify: update | insert
    - Apply admin_locked_fields per-row via CASE-per-field
    - INSERT new events
    - UPDATE existing events (only unlocked fields)
    - Bulk INSERT event_tag_queue

  Returns jsonb { imported, updated, skipped, enqueued }.

  Idempotent — UNIQUE partial index on (source_id, source_url) catches
  any concurrent insert and the planner short-circuits via the existing
  ON CONFLICT path.

  Cross-source dedup (title + start + city) is intentionally excluded here.
  The per-row LATERAL scan was O(N×events) with no usable index. That work
  runs as a separate periodic job instead.
*/

BEGIN;

CREATE OR REPLACE FUNCTION private.bulk_import_scrape_events(
  p_run_id    uuid,
  p_source_id uuid,
  p_events    jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_auto_approve boolean;
  v_imported     int := 0;
  v_updated      int := 0;
  v_skipped      int := 0;
  v_enqueued     int := 0;
BEGIN
  SELECT auto_approve INTO v_auto_approve
  FROM public.event_sources WHERE id = p_source_id;

  IF v_auto_approve IS NULL THEN
    RAISE EXCEPTION 'source not found: %', p_source_id USING ERRCODE = 'P0002';
  END IF;

  -- =============================================================
  -- 1. Expand jsonb input to typed rows + classify each
  -- =============================================================
  -- inputs:    parsed event payload (text/numeric typed)
  -- classified: adds source_url_match via UNIQUE(source_id, source_url) index
  -- decision:  'insert' | 'update'
  -- =============================================================
  CREATE TEMP TABLE _bulk_input ON COMMIT DROP AS
  WITH inputs AS (
    SELECT
      (idx - 1)::int AS ord,
      (elem->>'title')::text                    AS title,
      (elem->>'description')::text              AS description,
      (elem->>'start_datetime')::timestamptz    AS start_datetime,
      NULLIF(elem->>'end_datetime', '')::timestamptz AS end_datetime,
      (elem->>'timezone')::text                 AS timezone,
      (elem->>'venue_name')::text               AS venue_name,
      (elem->>'address')::text                  AS address,
      NULLIF(elem->>'city_id', '')::uuid        AS city_id,
      NULLIF(elem->>'source_url', '')::text     AS source_url,
      (elem->>'source_name')::text              AS source_name,
      COALESCE(elem->'images', '[]'::jsonb)     AS images,
      NULLIF(elem->>'price', '')::numeric       AS price,
      COALESCE((elem->>'is_free')::boolean, false) AS is_free,
      NULLIF(elem->>'is_outdoor', '')::boolean  AS is_outdoor,
      NULLIF(elem->>'latitude', '')::numeric    AS latitude,
      NULLIF(elem->>'longitude', '')::numeric   AS longitude
    FROM jsonb_array_elements(p_events) WITH ORDINALITY AS j(elem, idx)
  ),
  classified AS (
    SELECT
      i.*,
      su.id AS source_url_match
    FROM inputs i
    LEFT JOIN LATERAL (
      SELECT e.id FROM public.events e
      WHERE e.source_id = p_source_id
        AND e.source_url IS NOT NULL
        AND e.source_url = i.source_url
      LIMIT 1
    ) su ON i.source_url IS NOT NULL
  )
  SELECT
    c.*,
    CASE
      WHEN c.source_url_match IS NOT NULL THEN 'update'
      ELSE 'insert'
    END AS decision,
    c.source_url_match AS target_event_id
  FROM classified c;

  -- =============================================================
  -- 2. INSERT new events
  --    23505 (partial UNIQUE on source_id+source_url) → ignored: a
  --    concurrent run already inserted this row. Re-classifies as
  --    'update' below via _bulk_inserted reconciliation.
  -- =============================================================
  CREATE TEMP TABLE _bulk_inserted ON COMMIT DROP AS
  WITH src AS (
    SELECT * FROM _bulk_input WHERE decision = 'insert'
  ),
  ins AS (
    INSERT INTO public.events (
      title, description, start_datetime, end_datetime, timezone,
      venue_name, address, city_id, latitude, longitude,
      price, is_free, is_outdoor,
      source_url, source_name, source_id,
      images, status
    )
    SELECT
      s.title, s.description, s.start_datetime, s.end_datetime, s.timezone,
      s.venue_name, s.address, s.city_id, s.latitude, s.longitude,
      s.price, s.is_free, s.is_outdoor,
      s.source_url, s.source_name, p_source_id,
      s.images,
      CASE WHEN v_auto_approve THEN 'published' ELSE 'draft' END
    FROM src s
    ON CONFLICT (source_id, source_url)
      WHERE source_url IS NOT NULL
      DO NOTHING
    RETURNING id, source_url
  )
  SELECT id, source_url FROM ins;

  GET DIAGNOSTICS v_imported = ROW_COUNT;

  -- For any 'insert' that hit ON CONFLICT (concurrent inserter raced us),
  -- look the existing row up and treat as an update target.
  CREATE TEMP TABLE _bulk_update_targets ON COMMIT DROP AS
  SELECT b.*, e.id AS event_id, e.admin_locked_fields
  FROM _bulk_input b
  JOIN public.events e
    ON e.source_id = p_source_id
   AND e.source_url IS NOT NULL
   AND e.source_url = b.source_url
  WHERE b.decision = 'update'
     OR (b.decision = 'insert' AND b.source_url IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM _bulk_inserted i WHERE i.source_url = b.source_url));

  -- =============================================================
  -- 3. UPDATE existing events. Per-row admin_locked_fields exclusion
  --    via CASE-per-field: locked → keep existing, unlocked → use new.
  -- =============================================================
  WITH updated AS (
    UPDATE public.events e SET
      title          = CASE WHEN 'title'          = ANY(e.admin_locked_fields) THEN e.title          ELSE t.title          END,
      description    = CASE WHEN 'description'    = ANY(e.admin_locked_fields) THEN e.description    ELSE t.description    END,
      start_datetime = CASE WHEN 'start_datetime' = ANY(e.admin_locked_fields) THEN e.start_datetime ELSE t.start_datetime END,
      end_datetime   = CASE WHEN 'end_datetime'   = ANY(e.admin_locked_fields) THEN e.end_datetime   ELSE t.end_datetime   END,
      timezone       = CASE WHEN 'timezone'       = ANY(e.admin_locked_fields) THEN e.timezone       ELSE t.timezone       END,
      venue_name     = CASE WHEN 'venue_name'     = ANY(e.admin_locked_fields) THEN e.venue_name     ELSE t.venue_name     END,
      address        = CASE WHEN 'address'        = ANY(e.admin_locked_fields) THEN e.address        ELSE t.address        END,
      city_id        = CASE WHEN 'city_id'        = ANY(e.admin_locked_fields) THEN e.city_id        ELSE t.city_id        END,
      source_url     = CASE WHEN 'source_url'     = ANY(e.admin_locked_fields) THEN e.source_url     ELSE t.source_url     END,
      source_name    = CASE WHEN 'source_name'    = ANY(e.admin_locked_fields) THEN e.source_name    ELSE t.source_name    END,
      source_id      = CASE WHEN 'source_id'      = ANY(e.admin_locked_fields) THEN e.source_id      ELSE p_source_id      END,
      images         = CASE WHEN 'images'         = ANY(e.admin_locked_fields) THEN e.images         ELSE t.images         END,
      price          = CASE WHEN 'price'          = ANY(e.admin_locked_fields) THEN e.price          ELSE t.price          END,
      is_free        = CASE WHEN 'is_free'        = ANY(e.admin_locked_fields) THEN e.is_free        ELSE t.is_free        END,
      is_outdoor     = CASE WHEN 'is_outdoor'     = ANY(e.admin_locked_fields) THEN e.is_outdoor     ELSE t.is_outdoor     END,
      status         = CASE WHEN 'status'         = ANY(e.admin_locked_fields) THEN e.status         ELSE e.status         END,
      updated_at     = now()
    FROM _bulk_update_targets t
    WHERE e.id = t.event_id
    RETURNING e.id
  )
  SELECT COUNT(*) INTO v_updated FROM updated;

  -- =============================================================
  -- 4. Enqueue event_tag_queue for every imported / updated row.
  --    23505 (partial UNIQUE on event_id WHERE status NOT IN
  --    ('succeeded','dead')) is benign — row already queued.
  -- =============================================================
  WITH all_imported AS (
    SELECT id FROM _bulk_inserted
    UNION ALL
    SELECT event_id AS id FROM _bulk_update_targets
  ),
  enq AS (
    INSERT INTO public.event_tag_queue (event_id, source_run_id, trigger_type)
    SELECT id, p_run_id, 'import'
    FROM all_imported
    ON CONFLICT (event_id) WHERE status IN ('pending', 'processing')
      DO NOTHING
    RETURNING id
  )
  SELECT COUNT(*) INTO v_enqueued FROM enq;

  RETURN jsonb_build_object(
    'imported', v_imported,
    'updated',  v_updated,
    'skipped',  v_skipped,
    'enqueued', v_enqueued
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION private.bulk_import_scrape_events(uuid, uuid, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.bulk_import_scrape_events(uuid, uuid, jsonb)
  TO service_role;

CREATE OR REPLACE FUNCTION public.bulk_import_scrape_events(
  p_run_id    uuid,
  p_source_id uuid,
  p_events    jsonb
)
RETURNS jsonb
LANGUAGE sql
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.bulk_import_scrape_events(p_run_id, p_source_id, p_events);
$$;

REVOKE EXECUTE ON FUNCTION public.bulk_import_scrape_events(uuid, uuid, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.bulk_import_scrape_events(uuid, uuid, jsonb)
  TO service_role;

COMMENT ON FUNCTION public.bulk_import_scrape_events(uuid, uuid, jsonb) IS
  'Bulk-import a batch of parsed events for a single scrape run. JS-side prepares
   the jsonb payload (with geocoded coords, sanitized images) and calls
   this once instead of looping per-event. Returns {imported, updated, skipped, enqueued}.';

COMMIT;


-- ============================================================================
-- Source: 20260601007001_cursor_events_rpcs.sql
-- ============================================================================

-- §2: Cursor-based pagination RPCs for events_enriched and search_events.

BEGIN;

-- ---------------------------------------------------------------------------
-- Indexes: composite (start_datetime, id) for keyset pagination.
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS events_published_start_id_idx
  ON public.events (start_datetime, id)
  WHERE status = 'published';

-- events_published_city_start_id_idx duplicates events_published_feed_idx from
-- 006800; dropped in 007600 to keep advisor lint clean.

-- ---------------------------------------------------------------------------
-- Function 1: events_enriched_v2
-- Adds keyset cursor params (p_after_start_datetime, p_after_id) to v1.
-- ---------------------------------------------------------------------------

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
  id               uuid,
  title            text,
  description      text,
  start_datetime   timestamptz,
  end_datetime     timestamptz,
  timezone         text,
  venue_name       text,
  address          text,
  city_id          uuid,
  latitude         numeric,
  longitude        numeric,
  age_min          integer,
  age_max          integer,
  price            numeric,
  is_free          boolean,
  source_url       text,
  source_name      text,
  source_id        uuid,
  images           jsonb,
  status           text,
  ai_confidence    numeric,
  ai_tag_provider  text,
  recurrence_info  jsonb,
  is_featured      boolean,
  view_count       integer,
  search_vector    tsvector,
  created_at       timestamptz,
  updated_at       timestamptz,
  avg_rating       numeric,
  rating_count     integer,
  tags             jsonb,
  is_favorited     boolean,
  is_in_calendar   boolean
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
GRANT ALL ON FUNCTION public.events_enriched_v2(
  uuid, text, uuid, uuid[], timestamptz, timestamptz, timestamptz, uuid, int
) TO anon;
GRANT ALL ON FUNCTION public.events_enriched_v2(
  uuid, text, uuid, uuid[], timestamptz, timestamptz, timestamptz, uuid, int
) TO authenticated;
GRANT ALL ON FUNCTION public.events_enriched_v2(
  uuid, text, uuid, uuid[], timestamptz, timestamptz, timestamptz, uuid, int
) TO service_role;

-- ---------------------------------------------------------------------------
-- Function 2: search_events_v2
-- Adds keyset cursor params to v1; cursor takes priority over p_offset when
-- p_after_start_datetime IS NOT NULL.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.search_events_v2(
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

REVOKE ALL ON FUNCTION public.search_events_v2(
  uuid, timestamptz, timestamptz, integer, integer, boolean, boolean,
  text[], text, text, integer, integer, timestamptz, uuid
) FROM PUBLIC;
GRANT ALL ON FUNCTION public.search_events_v2(
  uuid, timestamptz, timestamptz, integer, integer, boolean, boolean,
  text[], text, text, integer, integer, timestamptz, uuid
) TO anon;
GRANT ALL ON FUNCTION public.search_events_v2(
  uuid, timestamptz, timestamptz, integer, integer, boolean, boolean,
  text[], text, text, integer, integer, timestamptz, uuid
) TO authenticated;
GRANT ALL ON FUNCTION public.search_events_v2(
  uuid, timestamptz, timestamptz, integer, integer, boolean, boolean,
  text[], text, text, integer, integer, timestamptz, uuid
) TO service_role;

COMMIT;


-- ============================================================================
-- Source: 20260601007100_admin_events_enriched.sql
-- ============================================================================

BEGIN;

-- ============================================================
-- private.admin_events_enriched  (SECURITY DEFINER body)
-- ============================================================
CREATE OR REPLACE FUNCTION private.admin_events_enriched(
  p_status            text        DEFAULT NULL::text,
  p_city_id           uuid        DEFAULT NULL::uuid,
  p_city_is_null      boolean     DEFAULT NULL::boolean,
  p_keyword           text        DEFAULT NULL::text,
  p_after_created_at  timestamptz DEFAULT NULL::timestamptz,
  p_after_id          uuid        DEFAULT NULL::uuid,
  p_limit             int         DEFAULT 50
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
  WITH filtered AS (
    SELECT e.*
    FROM public.events e
    WHERE
      (p_status IS NULL OR e.status = p_status)
      AND (
        p_city_is_null IS NULL
        OR (p_city_is_null = true  AND e.city_id IS NULL)
        OR (p_city_is_null = false AND e.city_id IS NOT NULL)
      )
      AND (p_city_id IS NULL OR e.city_id = p_city_id)
      AND (
        p_keyword IS NULL
        OR e.title       ILIKE '%' || p_keyword || '%'
        OR e.description ILIKE '%' || p_keyword || '%'
      )
      AND (
        p_after_created_at IS NULL
        OR (e.created_at, e.id) < (p_after_created_at, p_after_id)
      )
    ORDER BY e.created_at DESC, e.id DESC
    LIMIT LEAST(GREATEST(p_limit, 1), 200)
  )
  SELECT
    f.id, f.title, f.description, f.start_datetime, f.end_datetime, f.timezone,
    f.venue_name, f.address, f.city_id, f.latitude, f.longitude,
    f.age_min, f.age_max, f.price, f.is_free,
    f.source_url, f.source_name, f.source_id, f.images, f.status,
    f.ai_confidence, f.ai_tag_provider, f.recurrence_info, f.is_featured, f.view_count,
    f.search_vector, f.admin_locked_fields, f.admin_last_edited_at, f.admin_last_edited_by,
    f.created_at, f.updated_at, f.ai_tag_model, f.ai_tag_status,
    COUNT(*) OVER ()::bigint AS total_count
  FROM filtered f;
END;
$$;

REVOKE EXECUTE ON FUNCTION private.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int)
  TO authenticated, service_role;

-- ============================================================
-- public.admin_events_enriched  (SECURITY INVOKER wrapper)
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_events_enriched(
  p_status            text        DEFAULT NULL::text,
  p_city_id           uuid        DEFAULT NULL::uuid,
  p_city_is_null      boolean     DEFAULT NULL::boolean,
  p_keyword           text        DEFAULT NULL::text,
  p_after_created_at  timestamptz DEFAULT NULL::timestamptz,
  p_after_id          uuid        DEFAULT NULL::uuid,
  p_limit             int         DEFAULT 50
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
  total_count           bigint
)
LANGUAGE sql
VOLATILE
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT * FROM private.admin_events_enriched(
    p_status, p_city_id, p_city_is_null, p_keyword,
    p_after_created_at, p_after_id, p_limit
  );
$$;

REVOKE EXECUTE ON FUNCTION public.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int)
  FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_events_enriched(text, uuid, boolean, text, timestamptz, uuid, int)
  TO authenticated;

/*
  Verification block (do not run in migration — execute manually after deploy):

  -- As authenticated admin:
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub', '<admin-user-id>', true);
  SELECT count(*) FROM public.admin_events_enriched();
  RESET ROLE;

  -- As service_role (postgres context mirrors service_role):
  SELECT count(*) FROM public.admin_events_enriched();
*/

COMMIT;


-- ============================================================================
-- Source: 20260601007101_event_enrichment_backfill.sql
-- ============================================================================

/*
  # Event enrichment backfill

  Phase 2 of the bulk-scrape rewrite (20260601007000) intentionally dropped
  per-event geocode + image HEAD HTTP work from the scrape hot path — those
  HTTPs were the long pole on the 150s edge wall (460 new events × 2 HTTPs
  × 500ms = 460s+). The scrape RPC now leaves `latitude/longitude` NULL and
  `images = []` on freshly inserted rows.

  This migration adds the missing backfill plumbing:
    - private.list_events_needing_enrichment(p_limit) — claim batch of
      events where coords are NULL or images is empty AND the field isn't
      admin-locked. Returns the source's `url` + city context so the edge
      function has everything it needs without a second round-trip.
    - private.update_event_enrichment(p_event_id, p_latitude, p_longitude,
      p_images) — UPDATE events honoring admin_locked_fields per-field, so
      we never overwrite an admin's manual coord/image edit.
    - cron-enrich-events added to private.cron_enabled + the Railway
      allowlist (admin UI list_railway_cron_jobs).
*/

BEGIN;

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
    (e.latitude IS NULL OR e.longitude IS NULL)
       AND NOT 'latitude'  = ANY(e.admin_locked_fields)
       AND NOT 'longitude' = ANY(e.admin_locked_fields)
       AS needs_coords,
    (e.images = '[]'::jsonb OR jsonb_array_length(e.images) = 0)
       AND NOT 'images' = ANY(e.admin_locked_fields)
       AS needs_images,
    e.admin_locked_fields
  FROM public.events e
  WHERE (
    (e.latitude IS NULL OR e.longitude IS NULL)
       AND NOT 'latitude'  = ANY(e.admin_locked_fields)
       AND NOT 'longitude' = ANY(e.admin_locked_fields)
  )
  OR (
    (e.images = '[]'::jsonb OR jsonb_array_length(e.images) = 0)
       AND NOT 'images' = ANY(e.admin_locked_fields)
  )
  ORDER BY e.created_at DESC
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
  admin_locked_fields text[]
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

CREATE OR REPLACE FUNCTION private.update_event_enrichment(
  p_event_id   uuid,
  p_latitude   numeric,
  p_longitude  numeric,
  p_images     jsonb
)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
  UPDATE public.events e SET
    latitude = CASE
      WHEN 'latitude' = ANY(e.admin_locked_fields) THEN e.latitude
      WHEN p_latitude IS NULL THEN e.latitude
      ELSE p_latitude
    END,
    longitude = CASE
      WHEN 'longitude' = ANY(e.admin_locked_fields) THEN e.longitude
      WHEN p_longitude IS NULL THEN e.longitude
      ELSE p_longitude
    END,
    images = CASE
      WHEN 'images' = ANY(e.admin_locked_fields) THEN e.images
      WHEN p_images IS NULL OR jsonb_array_length(p_images) = 0 THEN e.images
      ELSE p_images
    END,
    updated_at = now()
  WHERE e.id = p_event_id;
$$;

REVOKE EXECUTE ON FUNCTION private.update_event_enrichment(uuid, numeric, numeric, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.update_event_enrichment(uuid, numeric, numeric, jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.update_event_enrichment(
  p_event_id   uuid,
  p_latitude   numeric,
  p_longitude  numeric,
  p_images     jsonb
)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.update_event_enrichment(p_event_id, p_latitude, p_longitude, p_images);
$$;

REVOKE EXECUTE ON FUNCTION public.update_event_enrichment(uuid, numeric, numeric, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.update_event_enrichment(uuid, numeric, numeric, jsonb) TO service_role;

-- Seed the new cron label so the UI toggle + runner kill switch both work.
INSERT INTO private.cron_enabled (label) VALUES ('cron-enrich-events')
ON CONFLICT (label) DO NOTHING;

-- Extend the Railway cron allowlist. RETURNS TABLE shape unchanged so we
-- can CREATE OR REPLACE the body without dropping the dependent wrapper.
CREATE OR REPLACE FUNCTION private.list_railway_cron_jobs()
RETURNS TABLE (
  label               text,
  enabled             boolean,
  last_run_status     text,
  last_run_at         timestamptz,
  last_run_duration_s int,
  last_http_status    int
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH known AS (
    SELECT unnest(ARRAY[
      'cron-db-maintenance',
      'cron-tag-queue',
      'cron-scrape-sources',
      'cron-cleanup-stale',
      'cron-enrich-events'
    ]::text[]) AS label
  ),
  last_runs AS (
    SELECT DISTINCT ON (r.label)
      r.label, r.status, r.ran_at, r.duration_s, r.http_status
    FROM private.railway_cron_runs r
    ORDER BY r.label, r.ran_at DESC
  )
  SELECT
    k.label,
    COALESCE((SELECT ce.enabled FROM private.cron_enabled ce WHERE ce.label = k.label), true) AS enabled,
    lr.status,
    lr.ran_at,
    lr.duration_s,
    lr.http_status
  FROM known k
  LEFT JOIN last_runs lr ON lr.label = k.label
  ORDER BY k.label;
END;
$$;

COMMIT;


-- ============================================================================
-- Source: 20260601007200_revoke_default_public_function_grants.sql
-- ============================================================================

BEGIN;

-- Explicitly revoke anon from admin-only functions (belt-and-suspenders;
-- 006900 already granted only to authenticated/service_role).
REVOKE ALL ON FUNCTION public.admin_set_cron_enabled(text, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_set_cron_enabled(text, boolean) FROM anon;

-- Prevent future functions created in the public schema from being
-- automatically callable by PUBLIC.  Only affects functions created AFTER
-- this migration runs.
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

COMMIT;


-- ============================================================================
-- Source: 20260601007300_tighten_private_schema_usage.sql
-- ============================================================================

BEGIN;

-- Idempotent re-grant of USAGE on the private schema.
-- Ensures no accidental revoke has occurred since the original grants:
--   anon/authenticated: 20260601002200
--   service_role:       20260601005600_grant_private_schema_usage_service_role.sql
GRANT USAGE ON SCHEMA private TO anon, authenticated, service_role;

COMMIT;


-- ============================================================================
-- Source: 20260601007400_admin_db_health.sql
-- ============================================================================

BEGIN;

-- ============================================================
-- private.admin_db_health_snapshot  (SECURITY DEFINER body)
-- ============================================================
CREATE OR REPLACE FUNCTION private.admin_db_health_snapshot()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'tag_queue_by_status',
    (SELECT jsonb_object_agg(status, row_count) FROM public.event_tag_queue_summary),

    'source_queue_by_status',
    (SELECT jsonb_object_agg(status, row_count) FROM public.source_scrape_queue_summary),

    'tag_queue_oldest_pending',
    (SELECT oldest_enqueued_at FROM public.event_tag_queue_summary WHERE status = 'pending' LIMIT 1),

    'source_queue_oldest_pending',
    (SELECT oldest_enqueued_at FROM public.source_scrape_queue_summary WHERE status = 'pending' LIMIT 1),

    'tag_queue_dead',
    (SELECT COALESCE(row_count, 0) FROM public.event_tag_queue_summary WHERE status = 'dead' LIMIT 1),

    'tag_queue_failed',
    (SELECT COALESCE(row_count, 0) FROM public.event_tag_queue_summary WHERE status = 'failed' LIMIT 1),

    'source_runs_stuck_running',
    (SELECT COUNT(*) FROM public.source_runs WHERE status = 'running' AND started_at < now() - interval '15 minutes'),

    'recent_cron_runs_by_label_status',
    (
      WITH cron_stats AS (
        SELECT
          label,
          COUNT(*) FILTER (WHERE status = 'success') AS succeeded,
          COUNT(*) FILTER (WHERE status = 'error')   AS failed
        FROM private.railway_cron_runs
        WHERE ran_at >= now() - interval '24 hours'
        GROUP BY label
      )
      SELECT jsonb_object_agg(
        label,
        jsonb_build_object('succeeded', succeeded, 'failed', failed)
      )
      FROM cron_stats
    ),

    'snapshot_at', now()
  ) INTO v_result;

  RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION private.admin_db_health_snapshot() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.admin_db_health_snapshot() TO authenticated, service_role;

-- ============================================================
-- public.admin_db_health_snapshot  (SECURITY INVOKER wrapper)
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_db_health_snapshot()
RETURNS jsonb
LANGUAGE sql
VOLATILE
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT private.admin_db_health_snapshot();
$$;

REVOKE EXECUTE ON FUNCTION public.admin_db_health_snapshot() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_db_health_snapshot() TO authenticated;

COMMIT;


-- ============================================================================
-- Source: 20260601007500_trace_retention.sql
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION "private"."run_daily_maintenance"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_event_tag_pruned          int;
  v_invite_request_pruned     int;
  v_invite_redemption_pruned  int;
  v_rec_pruned                int;
  v_ai_traces_pruned          int;
  v_extraction_traces_pruned  int;
BEGIN
  DELETE FROM public.event_tag_queue
  WHERE (status = 'dead'   AND finished_at < now() - interval '30 days')
     OR (status = 'failed' AND finished_at < now() - interval '7 days');
  GET DIAGNOSTICS v_event_tag_pruned = ROW_COUNT;

  DELETE FROM public.invite_request_attempts
  WHERE attempted_at < now() - interval '30 days';
  GET DIAGNOSTICS v_invite_request_pruned = ROW_COUNT;

  DELETE FROM public.invite_redemption_attempts
  WHERE attempted_at < now() - interval '30 days';
  GET DIAGNOSTICS v_invite_redemption_pruned = ROW_COUNT;

  DELETE FROM public.recommendation_signals
  WHERE created_at < now() - interval '90 days';
  GET DIAGNOSTICS v_rec_pruned = ROW_COUNT;

  DELETE FROM public.event_ai_traces
  WHERE created_at < now() - interval '90 days';
  GET DIAGNOSTICS v_ai_traces_pruned = ROW_COUNT;

  DELETE FROM public.source_extraction_traces
  WHERE created_at < now() - interval '90 days';
  GET DIAGNOSTICS v_extraction_traces_pruned = ROW_COUNT;

  RETURN jsonb_build_object(
    'event_tag_queue_pruned',              v_event_tag_pruned,
    'invite_request_attempts_pruned',      v_invite_request_pruned,
    'invite_redemption_attempts_pruned',   v_invite_redemption_pruned,
    'recommendation_signals_pruned',       v_rec_pruned,
    'ai_traces_pruned',                    v_ai_traces_pruned,
    'extraction_traces_pruned',            v_extraction_traces_pruned,
    'ran_at',                              now()
  );
END;
$$;

COMMIT;

