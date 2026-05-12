-- Phase 3a/b: defensive length CHECKs + small function fixes
-- ----------------------------------------------------------------
-- Most of these are mechanical hardening flagged in the audit. Bundled
-- in one migration because none of them is risky on its own and they
-- share the "make existing data conform first, then constrain" pattern.

BEGIN;

-- =============================================
-- Length / shape bounds on user- and scraper-controlled text columns.
-- Truncate or reject pre-existing violations in a DO block first so the
-- CHECK doesn't block migration on legacy data.
-- =============================================

DO $$
DECLARE
  truncated int;
BEGIN
  -- events.title: cap at 500 chars. NOT NULL already.
  SELECT count(*) INTO truncated FROM public.events WHERE length(title) > 500;
  IF truncated > 0 THEN
    RAISE NOTICE 'value_bounds: truncating % events.title rows over 500 chars', truncated;
    UPDATE public.events SET title = left(title, 500) WHERE length(title) > 500;
  END IF;

  -- events.description: cap at 10000.
  SELECT count(*) INTO truncated FROM public.events WHERE length(description) > 10000;
  IF truncated > 0 THEN
    RAISE NOTICE 'value_bounds: truncating % events.description rows over 10000 chars', truncated;
    UPDATE public.events SET description = left(description, 10000) WHERE length(description) > 10000;
  END IF;

  -- events.address: cap at 500.
  SELECT count(*) INTO truncated FROM public.events WHERE length(address) > 500;
  IF truncated > 0 THEN
    RAISE NOTICE 'value_bounds: truncating % events.address rows over 500 chars', truncated;
    UPDATE public.events SET address = left(address, 500) WHERE length(address) > 500;
  END IF;

  -- events.venue_name: cap at 300.
  SELECT count(*) INTO truncated FROM public.events WHERE length(venue_name) > 300;
  IF truncated > 0 THEN
    RAISE NOTICE 'value_bounds: truncating % events.venue_name rows over 300 chars', truncated;
    UPDATE public.events SET venue_name = left(venue_name, 300) WHERE length(venue_name) > 300;
  END IF;

  -- events.images: must be a JSON array with at most 20 entries.
  SELECT count(*) INTO truncated
  FROM public.events
  WHERE jsonb_typeof(images) <> 'array' OR jsonb_array_length(images) > 20;
  IF truncated > 0 THEN
    RAISE NOTICE 'value_bounds: normalizing % events.images rows (wrong type or > 20 entries)', truncated;
    UPDATE public.events
    SET images = CASE
      WHEN jsonb_typeof(images) <> 'array' THEN '[]'::jsonb
      ELSE (
        SELECT coalesce(jsonb_agg(elem), '[]'::jsonb)
        FROM (
          SELECT elem
          FROM jsonb_array_elements(images) WITH ORDINALITY AS t(elem, ord)
          ORDER BY ord
          LIMIT 20
        ) capped
      )
    END
    WHERE jsonb_typeof(images) <> 'array' OR jsonb_array_length(images) > 20;
  END IF;

  -- comments.body: cap at 4000. NOT NULL already. Length must be at least 1
  -- (a non-empty body), so reject zero-length too. Trim then drop empty rows.
  UPDATE public.comments SET body = left(btrim(body), 4000)
    WHERE length(body) > 4000 OR body <> btrim(body);
  DELETE FROM public.comments WHERE length(btrim(body)) = 0;
END $$;

ALTER TABLE public.events
  ADD CONSTRAINT events_title_len_chk
    CHECK (length(title) <= 500);

ALTER TABLE public.events
  ADD CONSTRAINT events_description_len_chk
    CHECK (description IS NULL OR length(description) <= 10000);

ALTER TABLE public.events
  ADD CONSTRAINT events_address_len_chk
    CHECK (address IS NULL OR length(address) <= 500);

ALTER TABLE public.events
  ADD CONSTRAINT events_venue_name_len_chk
    CHECK (venue_name IS NULL OR length(venue_name) <= 300);

ALTER TABLE public.events
  ADD CONSTRAINT events_images_shape_chk
    CHECK (jsonb_typeof(images) = 'array' AND jsonb_array_length(images) <= 20);

ALTER TABLE public.comments
  ADD CONSTRAINT comments_body_len_chk
    CHECK (length(body) BETWEEN 1 AND 4000);

-- =============================================
-- Function fix: update_event_search_vector
-- Qualify regconfig with pg_catalog so search_path='' lookup is unambiguous.
-- =============================================
CREATE OR REPLACE FUNCTION public.update_event_search_vector()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.search_vector := to_tsvector(
    'pg_catalog.english'::regconfig,
    coalesce(NEW.title, '') || ' ' ||
    coalesce(NEW.description, '') || ' ' ||
    coalesce(NEW.venue_name, '') || ' ' ||
    coalesce(NEW.address, '')
  );
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

-- =============================================
-- Function fix: invites_required()
-- Case-insensitive and whitespace-tolerant parse so 'TRUE' / ' true ' / '1'
-- all enable invite gating. Default still fail-closed (gate on).
-- =============================================
CREATE OR REPLACE FUNCTION public.invites_required()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT lower(btrim(coalesce(current_setting('app.settings.require_invite', true), 'true')))
         IN ('true', 't', '1', 'yes');
$$;

-- =============================================
-- Function fix: handle_new_user
-- Repair half-provisioned rows on conflict instead of leaving stale state.
-- Only update is_enabled if enabled_at has never been set (i.e. fresh row
-- that another trigger raced past).
-- =============================================
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  invite_required boolean;
BEGIN
  invite_required :=
    lower(btrim(coalesce(current_setting('app.settings.require_invite', true), 'true')))
      IN ('true', 't', '1', 'yes');

  INSERT INTO public.user_profiles (id, email, display_name)
  VALUES (
    NEW.id,
    NEW.email,
    coalesce(NEW.raw_user_meta_data->>'display_name', split_part(NEW.email, '@', 1))
  )
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.user_access (
    user_id, is_enabled, enabled_at, disabled_at, disabled_reason, created_at, updated_at
  )
  VALUES (
    NEW.id,
    NOT invite_required,
    CASE WHEN invite_required THEN NULL ELSE now() END,
    NULL, NULL, now(), now()
  )
  ON CONFLICT (user_id) DO UPDATE
    SET
      is_enabled = EXCLUDED.is_enabled,
      enabled_at = EXCLUDED.enabled_at,
      updated_at = now()
    WHERE public.user_access.enabled_at IS NULL;

  RETURN NEW;
END;
$$;

-- =============================================
-- Function fix: search_events
-- Server-side escape % and _ in p_keyword so a wildcard in input can't expand
-- into a DoS-shaped ILIKE. Cap p_keyword length at 100 chars.
-- IMPORTANT: parameter list matches the original verbatim (name + type +
-- order) so CREATE OR REPLACE actually replaces the existing function.
-- =============================================
CREATE OR REPLACE FUNCTION public.search_events(
  p_city_id    uuid DEFAULT NULL,
  p_date_from  timestamptz DEFAULT NULL,
  p_date_to    timestamptz DEFAULT NULL,
  p_age_min    int DEFAULT NULL,
  p_age_max    int DEFAULT NULL,
  p_is_free    boolean DEFAULT NULL,
  p_is_featured boolean DEFAULT NULL,
  p_tag_slugs  text[] DEFAULT NULL,
  p_keyword    text DEFAULT NULL,
  p_status     text DEFAULT 'published',
  p_limit      int DEFAULT 100,
  p_offset     int DEFAULT 0
)
RETURNS SETOF public.events
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  WITH escaped_keyword AS (
    SELECT
      CASE
        WHEN p_keyword IS NULL OR p_keyword = '' THEN NULL
        WHEN length(p_keyword) > 100 THEN NULL
        -- Escape \, %, and _ so wildcards in user input cannot expand into a
        -- DoS-shaped ILIKE pattern. Client also calls sanitizePostgrestLike;
        -- this is defense in depth so the guarantee lives in the DB.
        ELSE replace(replace(replace(p_keyword, '\', '\\'), '%', '\%'), '_', '\_')
      END AS kw
  )
  SELECT e.*
  FROM public.events e, escaped_keyword
  WHERE e.status = p_status
    AND (p_city_id IS NULL OR e.city_id = p_city_id)
    AND (p_date_from IS NULL OR e.start_datetime >= p_date_from)
    AND (p_date_to IS NULL OR e.start_datetime <= p_date_to)
    AND (p_is_free IS NULL OR e.is_free = p_is_free)
    AND (p_is_featured IS NULL OR e.is_featured = p_is_featured)
    AND (p_age_min IS NULL OR COALESCE(e.age_max, 99) >= p_age_min)
    AND (p_age_max IS NULL OR COALESCE(e.age_min, 0) <= p_age_max)
    AND (
      escaped_keyword.kw IS NULL
      OR e.title ILIKE '%' || escaped_keyword.kw || '%' ESCAPE '\'
      OR e.description ILIKE '%' || escaped_keyword.kw || '%' ESCAPE '\'
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
  ORDER BY e.start_datetime ASC
  LIMIT p_limit OFFSET p_offset;
$$;

-- =============================================
-- RLS fix: prevent admin self-lockout on user_access.
-- An admin who toggles their own is_enabled = false would lose
-- private.is_admin() (which requires enabled_user) and could brick the
-- admin surface for everyone. Block the update at the policy layer.
-- =============================================
DROP POLICY IF EXISTS "Admins can update user access" ON public.user_access;
CREATE POLICY "Admins can update user access"
  ON public.user_access FOR UPDATE TO authenticated
  USING ((SELECT private.is_admin()))
  WITH CHECK (
    (SELECT private.is_admin())
    AND (user_id <> (SELECT auth.uid()) OR is_enabled = true)
  );

DROP POLICY IF EXISTS "Admins can delete user access" ON public.user_access;
CREATE POLICY "Admins can delete user access"
  ON public.user_access FOR DELETE TO authenticated
  USING (
    (SELECT private.is_admin())
    AND user_id <> (SELECT auth.uid())
  );

COMMIT;
