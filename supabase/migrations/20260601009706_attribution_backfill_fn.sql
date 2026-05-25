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
