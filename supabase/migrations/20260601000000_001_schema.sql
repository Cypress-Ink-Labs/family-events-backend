/*
  # Family Events Platform — Schema

  All tables, indexes, extensions, and FK constraints in dependency order.
  This is the canonical schema; no intermediate ALTER steps exist here.
*/

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;
CREATE EXTENSION IF NOT EXISTS cube WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS earthdistance WITH SCHEMA public;

CREATE SCHEMA IF NOT EXISTS private;

-- =============================================
-- cities
-- =============================================
CREATE TABLE IF NOT EXISTS public.cities (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name       text NOT NULL,
  state      text,
  country    text NOT NULL DEFAULT 'US',
  slug       text UNIQUE NOT NULL,
  is_active  boolean NOT NULL DEFAULT true,
  latitude   numeric(10,7),
  longitude  numeric(10,7),
  timezone   text NOT NULL DEFAULT 'America/Chicago',
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.cities ENABLE ROW LEVEL SECURITY;

-- =============================================
-- tags
-- =============================================
CREATE TABLE IF NOT EXISTS public.tags (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name       text NOT NULL UNIQUE,
  slug       text NOT NULL UNIQUE,
  color      text NOT NULL DEFAULT '#6b7280',
  category   text NOT NULL DEFAULT 'theme',
  is_system  boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.tags ENABLE ROW LEVEL SECURITY;

-- =============================================
-- user_profiles
-- =============================================
CREATE TABLE IF NOT EXISTS public.user_profiles (
  id                   uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email                text,
  display_name         text,
  avatar_url           text,
  role                 text NOT NULL DEFAULT 'user' CHECK (role IN ('user', 'admin')),
  city_preference_id   uuid,
  child_name           text,
  child_age            integer,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_profiles FORCE ROW LEVEL SECURITY;

-- =============================================
-- event_sources
-- =============================================
CREATE TABLE IF NOT EXISTS public.event_sources (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                 text NOT NULL,
  url                  text NOT NULL UNIQUE,
  source_type          text NOT NULL DEFAULT 'website'
                         CHECK (source_type IN ('website', 'ical', 'rss', 'manual')),
  city_id              uuid REFERENCES public.cities(id) ON DELETE SET NULL,
  is_active            boolean NOT NULL DEFAULT true,
  scrape_interval_hours integer NOT NULL DEFAULT 24,
  last_scraped_at      timestamptz,
  last_status          text DEFAULT 'pending'
                         CHECK (last_status IN ('pending', 'success', 'error', 'partial')),
  error_count          integer NOT NULL DEFAULT 0,
  notes                text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.event_sources ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS event_sources_city_id_idx ON public.event_sources(city_id);
CREATE UNIQUE INDEX IF NOT EXISTS event_sources_url_idx ON public.event_sources(url);

-- =============================================
-- source_runs
-- =============================================
CREATE TABLE IF NOT EXISTS public.source_runs (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id     uuid REFERENCES public.event_sources(id) ON DELETE CASCADE,
  started_at    timestamptz NOT NULL DEFAULT now(),
  completed_at  timestamptz,
  status        text NOT NULL DEFAULT 'running'
                  CHECK (status IN ('running', 'success', 'error', 'partial')),
  events_found    integer NOT NULL DEFAULT 0,
  events_imported integer NOT NULL DEFAULT 0,
  events_skipped  integer NOT NULL DEFAULT 0,
  error_log       text,
  created_at      timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.source_runs ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS source_runs_source_id_idx ON public.source_runs(source_id);

-- =============================================
-- events
-- =============================================
CREATE TABLE IF NOT EXISTS public.events (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title            text NOT NULL,
  description      text,
  start_datetime   timestamptz NOT NULL,
  end_datetime     timestamptz,
  timezone         text NOT NULL DEFAULT 'America/Chicago',
  venue_name       text,
  address          text,
  city_id          uuid REFERENCES public.cities(id) ON DELETE SET NULL,
  latitude         numeric(10,7),
  longitude        numeric(10,7),
  age_min          integer,
  age_max          integer,
  price            numeric(10,2),
  is_free          boolean NOT NULL DEFAULT false,
  source_url       text,
  source_name      text,
  source_id        uuid REFERENCES public.event_sources(id) ON DELETE SET NULL,
  images           jsonb NOT NULL DEFAULT '[]',
  status           text NOT NULL DEFAULT 'draft'
                     CHECK (status IN ('draft', 'published', 'rejected', 'archived')),
  ai_confidence    numeric(4,3) DEFAULT 0,
  ai_tag_provider  text
                     CHECK (ai_tag_provider IS NULL OR ai_tag_provider IN ('openai', 'keyword-fallback')),
  recurrence_info  jsonb,
  is_featured      boolean NOT NULL DEFAULT false,
  is_outdoor       boolean,
  view_count       integer NOT NULL DEFAULT 0,
  search_vector    tsvector,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.events ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS events_city_id_idx                ON public.events(city_id);
CREATE INDEX IF NOT EXISTS events_start_datetime_idx         ON public.events(start_datetime);
CREATE INDEX IF NOT EXISTS events_status_idx                 ON public.events(status);
CREATE INDEX IF NOT EXISTS events_is_featured_idx            ON public.events(is_featured);
CREATE INDEX IF NOT EXISTS events_search_vector_idx          ON public.events USING gin(search_vector);
CREATE INDEX IF NOT EXISTS events_status_start_datetime_idx  ON public.events(status, start_datetime);
CREATE INDEX IF NOT EXISTS events_city_id_start_datetime_idx ON public.events(city_id, start_datetime);
CREATE INDEX IF NOT EXISTS events_source_id_idx              ON public.events(source_id);
CREATE INDEX IF NOT EXISTS idx_events_ai_tag_provider
  ON public.events(ai_tag_provider) WHERE ai_tag_provider IS NOT NULL;

-- =============================================
-- event_tags
-- =============================================
CREATE TABLE IF NOT EXISTS public.event_tags (
  event_id           uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  tag_id             uuid NOT NULL REFERENCES public.tags(id) ON DELETE CASCADE,
  confidence         numeric(4,3) NOT NULL DEFAULT 1.0,
  is_manual_override boolean NOT NULL DEFAULT false,
  created_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (event_id, tag_id)
);
ALTER TABLE public.event_tags ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS event_tags_tag_id_idx ON public.event_tags(tag_id);

-- =============================================
-- favorites
-- =============================================
CREATE TABLE IF NOT EXISTS public.favorites (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  event_id   uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, event_id)
);
ALTER TABLE public.favorites ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS favorites_user_id_idx  ON public.favorites(user_id);
CREATE INDEX IF NOT EXISTS favorites_event_id_idx ON public.favorites(event_id);

-- =============================================
-- user_calendar_events
-- =============================================
CREATE TABLE IF NOT EXISTS public.user_calendar_events (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  event_id   uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  added_at   timestamptz NOT NULL DEFAULT now(),
  notes      text,
  UNIQUE(user_id, event_id)
);
ALTER TABLE public.user_calendar_events ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS user_calendar_events_user_id_idx  ON public.user_calendar_events(user_id);
CREATE INDEX IF NOT EXISTS user_calendar_events_event_id_idx ON public.user_calendar_events(event_id);

-- =============================================
-- ratings
-- =============================================
CREATE TABLE IF NOT EXISTS public.ratings (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  event_id   uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  score      integer NOT NULL CHECK (score BETWEEN 1 AND 5),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, event_id)
);
ALTER TABLE public.ratings ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS ratings_event_id_idx ON public.ratings(event_id);

-- =============================================
-- comments
-- =============================================
CREATE TABLE IF NOT EXISTS public.comments (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  event_id    uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  body        text NOT NULL,
  is_approved boolean NOT NULL DEFAULT true,
  is_flagged  boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.comments ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS comments_event_id_idx ON public.comments(event_id);
CREATE INDEX IF NOT EXISTS comments_user_id_idx  ON public.comments(user_id);

-- =============================================
-- recommendation_signals
-- =============================================
CREATE TABLE IF NOT EXISTS public.recommendation_signals (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  event_id    uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  signal_type text NOT NULL
                CHECK (signal_type IN ('view', 'favorite', 'calendar', 'rate', 'comment')),
  weight      numeric(4,2) NOT NULL DEFAULT 1.0,
  created_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.recommendation_signals ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS recommendation_signals_user_id_idx  ON public.recommendation_signals(user_id);
CREATE INDEX IF NOT EXISTS recommendation_signals_event_id_idx ON public.recommendation_signals(event_id);

-- =============================================
-- admin_audit_log
-- =============================================
CREATE TABLE IF NOT EXISTS public.admin_audit_log (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  action        text NOT NULL,
  target_type   text,
  target_id     uuid,
  metadata      jsonb,
  created_at    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.admin_audit_log ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS admin_audit_log_admin_user_id_idx ON public.admin_audit_log(admin_user_id);

-- Deferred FK: user_profiles.city_preference_id → cities
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'user_profiles_city_preference_id_fkey'
  ) THEN
    ALTER TABLE public.user_profiles
      ADD CONSTRAINT user_profiles_city_preference_id_fkey
      FOREIGN KEY (city_preference_id) REFERENCES public.cities(id) ON DELETE SET NULL;
  END IF;
END
$$;
CREATE INDEX IF NOT EXISTS user_profiles_city_preference_id_idx
  ON public.user_profiles(city_preference_id);

-- =============================================
-- invite_codes
-- =============================================
CREATE TABLE IF NOT EXISTS public.invite_codes (
  code        text PRIMARY KEY,
  max_uses    int NOT NULL DEFAULT 1 CHECK (max_uses > 0),
  used_count  int NOT NULL DEFAULT 0 CHECK (used_count >= 0),
  expires_at  timestamptz,
  notes       text,
  created_by  uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.invite_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invite_codes FORCE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS invite_codes_created_by_idx ON public.invite_codes(created_by);

-- =============================================
-- user_access
-- =============================================
CREATE TABLE IF NOT EXISTS public.user_access (
  user_id           uuid PRIMARY KEY REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  is_enabled        boolean NOT NULL DEFAULT false,
  access_expires_at timestamptz,
  enabled_at        timestamptz,
  disabled_at       timestamptz,
  disabled_reason   text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.user_access ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_access FORCE ROW LEVEL SECURITY;

-- =============================================
-- pending_invite_claims
-- =============================================
CREATE TABLE IF NOT EXISTS public.pending_invite_claims (
  email       text PRIMARY KEY,
  invite_code text NOT NULL REFERENCES public.invite_codes(code) ON DELETE CASCADE,
  expires_at  timestamptz NOT NULL DEFAULT (now() + interval '2 hours'),
  claimed_by  uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  claimed_at  timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.pending_invite_claims ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pending_invite_claims FORCE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS pending_invite_claims_claimed_by_idx
  ON public.pending_invite_claims(claimed_by);
CREATE INDEX IF NOT EXISTS pending_invite_claims_invite_code_idx
  ON public.pending_invite_claims(invite_code);

-- =============================================
-- event_ai_traces
-- =============================================
CREATE TABLE IF NOT EXISTS public.event_ai_traces (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id             uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  source_run_id        uuid REFERENCES public.source_runs(id) ON DELETE SET NULL,
  trigger_type         text NOT NULL DEFAULT 'import'
                         CHECK (trigger_type IN ('import', 'reclassify', 'manual-review')),
  provider             text NOT NULL
                         CHECK (provider IN ('openai', 'keyword-fallback')),
  model                text,
  status               text NOT NULL DEFAULT 'success'
                         CHECK (status IN ('success', 'fallback', 'error')),
  input_title          text NOT NULL,
  input_description    text,
  available_tag_slugs  jsonb NOT NULL DEFAULT '[]'::jsonb,
  predicted_tags       jsonb NOT NULL DEFAULT '[]'::jsonb,
  predicted_fields     jsonb,
  reasoning_summary    text,
  fallback_reason      text,
  processing_ms        integer,
  created_at           timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.event_ai_traces ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS event_ai_traces_event_id_created_at_idx
  ON public.event_ai_traces(event_id, created_at DESC);
CREATE INDEX IF NOT EXISTS event_ai_traces_source_run_id_idx
  ON public.event_ai_traces(source_run_id) WHERE source_run_id IS NOT NULL;

-- =============================================
-- public_events view
-- Whitelisted columns for anon/share-preview access. Defined here (with the
-- schema, not in the views file) because anon policies on event_tags, ratings,
-- and comments reference it inside their USING clauses, and CREATE POLICY
-- resolves expression names at creation time.
--
-- security_invoker = false (Postgres default) is explicit: the view executes
-- as its owner, bypassing RLS on public.events. This is the entire point of
-- the view — anon has no SELECT policy on events, but receives a SELECT grant
-- on this filtered, column-whitelisted projection.
-- =============================================
CREATE OR REPLACE VIEW public.public_events
WITH (security_invoker = false) AS
SELECT
  e.id,
  e.title,
  e.description,
  e.start_datetime,
  e.end_datetime,
  e.timezone,
  e.venue_name,
  e.address,
  e.city_id,
  e.latitude,
  e.longitude,
  e.age_min,
  e.age_max,
  e.price,
  e.is_free,
  e.source_url,
  e.source_name,
  e.images,
  e.recurrence_info,
  e.is_featured
FROM public.events e
WHERE e.status = 'published';

GRANT SELECT ON public.public_events TO anon, authenticated;
