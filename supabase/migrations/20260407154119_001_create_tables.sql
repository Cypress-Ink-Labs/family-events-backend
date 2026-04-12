
/*
  # Family Events Platform - Create All Tables
  
  Creates all core tables in dependency order. RLS policies that reference
  user_profiles are added in the next migration after user_profiles exists.

  ## Tables Created (in order)
  1. cities - supported event cities
  2. tags - event classification tags
  3. user_profiles - extended auth user data (references auth.users)
  4. event_sources - admin-managed scraping sources
  5. source_runs - scrape job execution log
  6. events - core event entities
  7. event_tags - event/tag many-to-many
  8. favorites - user favorited events
  9. user_calendar_events - events added to personal calendar
  10. ratings - user star ratings
  11. comments - user comments with moderation
  12. recommendation_signals - interaction tracking for recommendations
  13. admin_audit_log - immutable admin action log
*/

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- =============================================
-- TABLE: cities
-- =============================================
CREATE TABLE IF NOT EXISTS cities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  state text,
  country text NOT NULL DEFAULT 'US',
  slug text UNIQUE NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  latitude numeric(10,7),
  longitude numeric(10,7),
  timezone text NOT NULL DEFAULT 'America/New_York',
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE cities ENABLE ROW LEVEL SECURITY;

-- =============================================
-- TABLE: tags
-- =============================================
CREATE TABLE IF NOT EXISTS tags (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE,
  slug text NOT NULL UNIQUE,
  color text NOT NULL DEFAULT '#6b7280',
  category text NOT NULL DEFAULT 'theme',
  is_system boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE tags ENABLE ROW LEVEL SECURITY;

-- =============================================
-- TABLE: user_profiles
-- =============================================
CREATE TABLE IF NOT EXISTS user_profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email text,
  display_name text,
  avatar_url text,
  role text NOT NULL DEFAULT 'user' CHECK (role IN ('user', 'admin')),
  city_preference_id uuid,
  child_name text,
  child_age integer,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE user_profiles ENABLE ROW LEVEL SECURITY;

-- =============================================
-- TABLE: event_sources
-- =============================================
CREATE TABLE IF NOT EXISTS event_sources (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  url text NOT NULL,
  source_type text NOT NULL DEFAULT 'website' CHECK (source_type IN ('website', 'ical', 'rss', 'manual')),
  city_id uuid REFERENCES cities(id) ON DELETE SET NULL,
  is_active boolean NOT NULL DEFAULT true,
  scrape_interval_hours integer NOT NULL DEFAULT 24,
  last_scraped_at timestamptz,
  last_status text DEFAULT 'pending' CHECK (last_status IN ('pending', 'success', 'error', 'partial')),
  error_count integer NOT NULL DEFAULT 0,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE event_sources ENABLE ROW LEVEL SECURITY;

-- =============================================
-- TABLE: source_runs
-- =============================================
CREATE TABLE IF NOT EXISTS source_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id uuid REFERENCES event_sources(id) ON DELETE CASCADE,
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  status text NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'success', 'error', 'partial')),
  events_found integer NOT NULL DEFAULT 0,
  events_imported integer NOT NULL DEFAULT 0,
  events_skipped integer NOT NULL DEFAULT 0,
  error_log text,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE source_runs ENABLE ROW LEVEL SECURITY;

-- =============================================
-- TABLE: events
-- =============================================
CREATE TABLE IF NOT EXISTS events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL,
  description text,
  start_datetime timestamptz NOT NULL,
  end_datetime timestamptz,
  timezone text NOT NULL DEFAULT 'America/New_York',
  venue_name text,
  address text,
  city_id uuid REFERENCES cities(id) ON DELETE SET NULL,
  latitude numeric(10,7),
  longitude numeric(10,7),
  age_min integer,
  age_max integer,
  price numeric(10,2),
  is_free boolean NOT NULL DEFAULT false,
  source_url text,
  source_name text,
  source_id uuid REFERENCES event_sources(id) ON DELETE SET NULL,
  images jsonb NOT NULL DEFAULT '[]',
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'published', 'rejected', 'archived')),
  ai_confidence numeric(4,3) DEFAULT 0,
  recurrence_info jsonb,
  is_featured boolean NOT NULL DEFAULT false,
  view_count integer NOT NULL DEFAULT 0,
  search_vector tsvector,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE events ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS events_city_id_idx ON events(city_id);
CREATE INDEX IF NOT EXISTS events_start_datetime_idx ON events(start_datetime);
CREATE INDEX IF NOT EXISTS events_status_idx ON events(status);
CREATE INDEX IF NOT EXISTS events_is_featured_idx ON events(is_featured);
CREATE INDEX IF NOT EXISTS events_search_vector_idx ON events USING gin(search_vector);

CREATE OR REPLACE FUNCTION update_event_search_vector()
RETURNS TRIGGER AS $$
BEGIN
  NEW.search_vector := to_tsvector('english',
    coalesce(NEW.title, '') || ' ' ||
    coalesce(NEW.description, '') || ' ' ||
    coalesce(NEW.venue_name, '') || ' ' ||
    coalesce(NEW.address, '')
  );
  NEW.updated_at := now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS events_search_vector_trigger ON events;
CREATE TRIGGER events_search_vector_trigger
  BEFORE INSERT OR UPDATE ON events
  FOR EACH ROW EXECUTE FUNCTION update_event_search_vector();

-- =============================================
-- TABLE: event_tags
-- =============================================
CREATE TABLE IF NOT EXISTS event_tags (
  event_id uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  tag_id uuid NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  confidence numeric(4,3) NOT NULL DEFAULT 1.0,
  is_manual_override boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (event_id, tag_id)
);

ALTER TABLE event_tags ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS event_tags_tag_id_idx ON event_tags(tag_id);

-- =============================================
-- TABLE: favorites
-- =============================================
CREATE TABLE IF NOT EXISTS favorites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  event_id uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, event_id)
);

ALTER TABLE favorites ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS favorites_user_id_idx ON favorites(user_id);
CREATE INDEX IF NOT EXISTS favorites_event_id_idx ON favorites(event_id);

-- =============================================
-- TABLE: user_calendar_events
-- =============================================
CREATE TABLE IF NOT EXISTS user_calendar_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  event_id uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  added_at timestamptz NOT NULL DEFAULT now(),
  notes text,
  UNIQUE(user_id, event_id)
);

ALTER TABLE user_calendar_events ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS user_calendar_events_user_id_idx ON user_calendar_events(user_id);

-- =============================================
-- TABLE: ratings
-- =============================================
CREATE TABLE IF NOT EXISTS ratings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  event_id uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  score integer NOT NULL CHECK (score BETWEEN 1 AND 5),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, event_id)
);

ALTER TABLE ratings ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS ratings_event_id_idx ON ratings(event_id);

-- =============================================
-- TABLE: comments
-- =============================================
CREATE TABLE IF NOT EXISTS comments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  event_id uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  body text NOT NULL,
  is_approved boolean NOT NULL DEFAULT true,
  is_flagged boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE comments ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS comments_event_id_idx ON comments(event_id);

-- =============================================
-- TABLE: recommendation_signals
-- =============================================
CREATE TABLE IF NOT EXISTS recommendation_signals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  event_id uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  signal_type text NOT NULL CHECK (signal_type IN ('view', 'favorite', 'calendar', 'rate', 'comment')),
  weight numeric(4,2) NOT NULL DEFAULT 1.0,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE recommendation_signals ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS recommendation_signals_user_id_idx ON recommendation_signals(user_id);

-- =============================================
-- TABLE: admin_audit_log
-- =============================================
CREATE TABLE IF NOT EXISTS admin_audit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  action text NOT NULL,
  target_type text,
  target_id uuid,
  metadata jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE admin_audit_log ENABLE ROW LEVEL SECURITY;

-- Add deferred FK for user_profiles.city_preference_id
ALTER TABLE user_profiles
  ADD CONSTRAINT user_profiles_city_preference_id_fkey
  FOREIGN KEY (city_preference_id) REFERENCES cities(id) ON DELETE SET NULL;

-- Auto-create profile on user signup
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO user_profiles (id, email, display_name)
  VALUES (
    NEW.id,
    NEW.email,
    coalesce(NEW.raw_user_meta_data->>'display_name', split_part(NEW.email, '@', 1))
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();
