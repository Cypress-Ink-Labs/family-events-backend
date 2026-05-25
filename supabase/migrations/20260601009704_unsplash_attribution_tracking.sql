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
  LIMIT CASE WHEN p_event_ids IS NULL THEN LEAST(GREATEST(p_limit, 1), 200) ELSE NULL END;
$$;

REVOKE ALL ON FUNCTION public.events_enriched_v2(
  uuid, text, uuid, uuid[], timestamptz, timestamptz, timestamptz, uuid, int
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.events_enriched_v2(
  uuid, text, uuid, uuid[], timestamptz, timestamptz, timestamptz, uuid, int
) TO anon, authenticated, service_role;

COMMIT;
