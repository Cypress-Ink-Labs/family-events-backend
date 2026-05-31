-- Community event submission RPC.
-- Allows authenticated, enabled users to submit events for admin review.
-- Uses private body + public wrapper pattern per project convention.
-- Rate limited: max 5 submissions per user per 24 hours.

-- Add submitted_by column to events table to track community submissions
ALTER TABLE public.events ADD COLUMN IF NOT EXISTS submitted_by uuid
  REFERENCES auth.users(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.events.submitted_by IS
  'User who submitted this community event. NULL for scraped events.';

-- Private implementation
CREATE OR REPLACE FUNCTION private.submit_community_event_impl(
  p_title text,
  p_description text DEFAULT NULL,
  p_start_datetime timestamptz DEFAULT NULL,
  p_end_datetime timestamptz DEFAULT NULL,
  p_venue_name text DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_city_id uuid DEFAULT NULL,
  p_age_min integer DEFAULT NULL,
  p_age_max integer DEFAULT NULL,
  p_is_free boolean DEFAULT true,
  p_price numeric DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_user_id uuid;
  v_recent_count integer;
  v_event_id uuid;
BEGIN
  -- Must be authenticated
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  -- Must be enabled
  IF NOT private.has_enabled_access() THEN
    RAISE EXCEPTION 'Account not enabled' USING ERRCODE = '42501';
  END IF;

  -- Validate required fields
  IF p_title IS NULL OR btrim(p_title) = '' THEN
    RAISE EXCEPTION 'Title is required' USING ERRCODE = '22023';
  END IF;
  IF p_start_datetime IS NULL THEN
    RAISE EXCEPTION 'Start date/time is required' USING ERRCODE = '22023';
  END IF;
  IF p_city_id IS NULL THEN
    RAISE EXCEPTION 'City is required' USING ERRCODE = '22023';
  END IF;

  -- Rate limit: max 5 per user per 24h
  SELECT count(*) INTO v_recent_count
  FROM public.events
  WHERE submitted_by = v_user_id
    AND source_name = 'community'
    AND created_at > now() - interval '24 hours';

  IF v_recent_count >= 5 THEN
    RAISE EXCEPTION 'Daily submission limit reached (max 5 per day)'
      USING ERRCODE = '54000'; -- program_limit_exceeded
  END IF;

  -- Insert the event
  INSERT INTO public.events (
    title,
    description,
    start_datetime,
    end_datetime,
    venue_name,
    address,
    city_id,
    age_min,
    age_max,
    is_free,
    price,
    status,
    source_name,
    submitted_by,
    ai_confidence,
    llm_review_status
  ) VALUES (
    btrim(p_title),
    NULLIF(btrim(COALESCE(p_description, '')), ''),
    p_start_datetime,
    p_end_datetime,
    NULLIF(btrim(COALESCE(p_venue_name, '')), ''),
    NULLIF(btrim(COALESCE(p_address, '')), ''),
    p_city_id,
    p_age_min,
    p_age_max,
    COALESCE(p_is_free, true),
    CASE WHEN COALESCE(p_is_free, true) THEN NULL ELSE p_price END,
    'draft',
    'community',
    v_user_id,
    0,
    'not_required'
  )
  RETURNING id INTO v_event_id;

  RETURN v_event_id;
END;
$$;

-- Public wrapper
CREATE OR REPLACE FUNCTION public.submit_community_event(
  p_title text,
  p_description text DEFAULT NULL,
  p_start_datetime timestamptz DEFAULT NULL,
  p_end_datetime timestamptz DEFAULT NULL,
  p_venue_name text DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_city_id uuid DEFAULT NULL,
  p_age_min integer DEFAULT NULL,
  p_age_max integer DEFAULT NULL,
  p_is_free boolean DEFAULT true,
  p_price numeric DEFAULT NULL
)
RETURNS uuid
LANGUAGE sql
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT private.submit_community_event_impl(
    p_title, p_description, p_start_datetime, p_end_datetime,
    p_venue_name, p_address, p_city_id, p_age_min, p_age_max,
    p_is_free, p_price
  );
$$;

-- Grant execute to authenticated only (not anon)
REVOKE ALL ON FUNCTION public.submit_community_event(text, text, timestamptz, timestamptz, text, text, uuid, integer, integer, boolean, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_community_event(text, text, timestamptz, timestamptz, text, text, uuid, integer, integer, boolean, numeric) TO authenticated;
