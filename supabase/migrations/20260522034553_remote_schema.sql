create extension if not exists "hypopg" with schema "extensions";

create extension if not exists "index_advisor" with schema "extensions";

create schema if not exists "pgmq";
create schema if not exists "private";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION private.bulk_import_scrape_events(p_run_id uuid, p_source_id uuid, p_events jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_auto_approve boolean;
  v_status       text;
  v_imported     int := 0;
  v_updated      int := 0;
  v_enqueued     int := 0;
BEGIN
  SELECT auto_approve INTO v_auto_approve
  FROM public.event_sources WHERE id = p_source_id;

  IF v_auto_approve IS NULL THEN
    RAISE EXCEPTION 'source not found: %', p_source_id USING ERRCODE = 'P0002';
  END IF;

  v_status := CASE WHEN v_auto_approve THEN 'published' ELSE 'draft' END;

  -- Single chained data-modifying WITH so we don't rely on TEMP TABLEs.
  -- TEMP TABLEs work at runtime but Postgres static analysis (db lint)
  -- can't see forward-referenced TEMP TABLEs across separate statements,
  -- producing noisy "relation does not exist" errors. CTE form is one
  -- statement, lint-clean, and identical semantics.
  --
  -- Data-modifying-CTE isolation in Postgres: each CTE sees the snapshot
  -- of target tables taken at statement start. `update_targets` therefore
  -- cannot see rows that `inserted` writes inside the same statement —
  -- which is exactly what we want, because every "update" row is a row
  -- that already existed before this RPC ran. The only overlap case
  -- (insert-that-fell-through ON CONFLICT) means a concurrent transaction
  -- inserted before us; that row IS visible in the snapshot.
  WITH inputs AS (
    SELECT
      (idx - 1)::int AS ord,
      (elem->>'title')::text                         AS title,
      (elem->>'description')::text                   AS description,
      (elem->>'start_datetime')::timestamptz         AS start_datetime,
      NULLIF(elem->>'end_datetime', '')::timestamptz AS end_datetime,
      (elem->>'timezone')::text                      AS timezone,
      (elem->>'venue_name')::text                    AS venue_name,
      (elem->>'address')::text                       AS address,
      NULLIF(elem->>'city_id', '')::uuid             AS city_id,
      NULLIF(elem->>'source_url', '')::text          AS source_url,
      (elem->>'source_name')::text                   AS source_name,
      COALESCE(elem->'images', '[]'::jsonb)          AS images,
      NULLIF(elem->>'price', '')::numeric            AS price,
      COALESCE((elem->>'is_free')::boolean, false)   AS is_free,
      NULLIF(elem->>'is_outdoor', '')::boolean       AS is_outdoor,
      NULLIF(elem->>'latitude', '')::numeric         AS latitude,
      NULLIF(elem->>'longitude', '')::numeric        AS longitude
    FROM jsonb_array_elements(p_events) WITH ORDINALITY AS j(elem, idx)
  ),
  classified AS (
    SELECT
      i.*,
      su.id AS source_url_match,
      CASE WHEN su.id IS NOT NULL THEN 'update' ELSE 'insert' END AS decision
    FROM inputs i
    LEFT JOIN LATERAL (
      SELECT e.id FROM public.events e
      WHERE e.source_id = p_source_id
        AND e.source_url IS NOT NULL
        AND e.source_url = i.source_url
      LIMIT 1
    ) su ON i.source_url IS NOT NULL
  ),
  inserted AS (
    INSERT INTO public.events (
      title, description, start_datetime, end_datetime, timezone,
      venue_name, address, city_id, latitude, longitude,
      price, is_free, is_outdoor,
      source_url, source_name, source_id,
      images, status
    )
    SELECT
      c.title, c.description, c.start_datetime, c.end_datetime, c.timezone,
      c.venue_name, c.address, c.city_id, c.latitude, c.longitude,
      c.price, c.is_free, c.is_outdoor,
      c.source_url, c.source_name, p_source_id,
      c.images, v_status
    FROM classified c
    WHERE c.decision = 'insert'
    ON CONFLICT (source_id, source_url)
      WHERE source_url IS NOT NULL
      DO NOTHING
    RETURNING id, source_url
  ),
  update_targets AS (
    SELECT c.*, e.id AS event_id, e.admin_locked_fields
    FROM classified c
    JOIN public.events e
      ON e.source_id = p_source_id
     AND e.source_url IS NOT NULL
     AND e.source_url = c.source_url
    WHERE c.decision = 'update'
       OR (
         c.decision = 'insert'
         AND c.source_url IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM inserted i WHERE i.source_url = c.source_url)
       )
  ),
  updated AS (
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
      updated_at     = now()
    FROM update_targets t
    WHERE e.id = t.event_id
    RETURNING e.id
  ),
  all_imported AS (
    SELECT id FROM inserted
    UNION ALL
    SELECT event_id AS id FROM update_targets
  ),
  enqueued AS (
    INSERT INTO public.event_tag_queue (event_id, source_run_id, trigger_type)
    SELECT id, p_run_id, 'import' FROM all_imported
    ON CONFLICT (event_id) WHERE status IN ('pending', 'processing')
      DO NOTHING
    RETURNING id
  )
  SELECT
    (SELECT COUNT(*) FROM inserted),
    (SELECT COUNT(*) FROM updated),
    (SELECT COUNT(*) FROM enqueued)
  INTO v_imported, v_updated, v_enqueued;

  RETURN jsonb_build_object(
    'imported', v_imported,
    'updated',  v_updated,
    'skipped',  0,
    'enqueued', v_enqueued
  );
END;
$function$
;


