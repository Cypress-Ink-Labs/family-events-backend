
/*
  # Family Events Platform - RLS Policies
  
  Applies Row Level Security policies to all tables.
  All policies check user authentication and ownership.
  Admin access is gated on user_profiles.role = 'admin'.

  ## Policy Summary
  - cities: public read, admin write
  - tags: public read, admin write
  - event_sources: admin only
  - source_runs: admin only
  - events: public read (published only), admin full access
  - event_tags: public read, admin write
  - user_profiles: own data only + admin read all
  - favorites: own data only
  - user_calendar_events: own data only
  - ratings: public read, authenticated write own
  - comments: public read (approved), authenticated write own, admin manage
  - recommendation_signals: own data only
  - admin_audit_log: admin only
*/

-- =============================================
-- CITIES policies
-- =============================================
CREATE POLICY "Cities public read"
  ON cities FOR SELECT
  TO anon, authenticated
  USING (is_active = true);

CREATE POLICY "Admins can insert cities"
  ON cities FOR INSERT
  TO authenticated
  WITH CHECK (
    EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin')
  );

CREATE POLICY "Admins can update cities"
  ON cities FOR UPDATE
  TO authenticated
  USING (EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "Admins can delete cities"
  ON cities FOR DELETE
  TO authenticated
  USING (EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'));

-- =============================================
-- TAGS policies
-- =============================================
CREATE POLICY "Tags public read"
  ON tags FOR SELECT
  TO anon, authenticated
  USING (true);

CREATE POLICY "Admins can insert tags"
  ON tags FOR INSERT
  TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "Admins can update tags"
  ON tags FOR UPDATE
  TO authenticated
  USING (EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "Admins can delete tags"
  ON tags FOR DELETE
  TO authenticated
  USING (EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'));

-- =============================================
-- USER_PROFILES policies
-- =============================================
CREATE POLICY "Users can view own profile"
  ON user_profiles FOR SELECT
  TO authenticated
  USING (auth.uid() = id);

CREATE POLICY "Admins can view all profiles"
  ON user_profiles FOR SELECT
  TO authenticated
  USING (EXISTS (SELECT 1 FROM user_profiles up WHERE up.id = auth.uid() AND up.role = 'admin'));

CREATE POLICY "Users can insert own profile"
  ON user_profiles FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = id);

CREATE POLICY "Users can update own profile"
  ON user_profiles FOR UPDATE
  TO authenticated
  USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

-- =============================================
-- EVENT_SOURCES policies
-- =============================================
CREATE POLICY "Admins can select sources"
  ON event_sources FOR SELECT
  TO authenticated
  USING (EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "Admins can insert sources"
  ON event_sources FOR INSERT
  TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "Admins can update sources"
  ON event_sources FOR UPDATE
  TO authenticated
  USING (EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "Admins can delete sources"
  ON event_sources FOR DELETE
  TO authenticated
  USING (EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'));

-- =============================================
-- SOURCE_RUNS policies
-- =============================================
CREATE POLICY "Admins can select source runs"
  ON source_runs FOR SELECT
  TO authenticated
  USING (EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "Admins can insert source runs"
  ON source_runs FOR INSERT
  TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'));

-- =============================================
-- EVENTS policies
-- =============================================
CREATE POLICY "Published events are public"
  ON events FOR SELECT
  TO anon, authenticated
  USING (status = 'published');

CREATE POLICY "Admins can select all events"
  ON events FOR SELECT
  TO authenticated
  USING (EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "Admins can insert events"
  ON events FOR INSERT
  TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "Admins can update events"
  ON events FOR UPDATE
  TO authenticated
  USING (EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "Admins can delete events"
  ON events FOR DELETE
  TO authenticated
  USING (EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'));

-- =============================================
-- EVENT_TAGS policies
-- =============================================
CREATE POLICY "Event tags public read"
  ON event_tags FOR SELECT
  TO anon, authenticated
  USING (true);

CREATE POLICY "Admins can insert event tags"
  ON event_tags FOR INSERT
  TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "Admins can update event tags"
  ON event_tags FOR UPDATE
  TO authenticated
  USING (EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "Admins can delete event tags"
  ON event_tags FOR DELETE
  TO authenticated
  USING (EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'));

-- =============================================
-- FAVORITES policies
-- =============================================
CREATE POLICY "Users can view own favorites"
  ON favorites FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

CREATE POLICY "Users can add favorites"
  ON favorites FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete own favorites"
  ON favorites FOR DELETE
  TO authenticated
  USING (auth.uid() = user_id);

-- =============================================
-- USER_CALENDAR_EVENTS policies
-- =============================================
CREATE POLICY "Users can view own calendar events"
  ON user_calendar_events FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

CREATE POLICY "Users can add calendar events"
  ON user_calendar_events FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete own calendar events"
  ON user_calendar_events FOR DELETE
  TO authenticated
  USING (auth.uid() = user_id);

-- =============================================
-- RATINGS policies
-- =============================================
CREATE POLICY "Ratings are public"
  ON ratings FOR SELECT
  TO anon, authenticated
  USING (true);

CREATE POLICY "Authenticated users can add ratings"
  ON ratings FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own ratings"
  ON ratings FOR UPDATE
  TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete own ratings"
  ON ratings FOR DELETE
  TO authenticated
  USING (auth.uid() = user_id);

-- =============================================
-- COMMENTS policies
-- =============================================
CREATE POLICY "Approved comments public read"
  ON comments FOR SELECT
  TO anon, authenticated
  USING (is_approved = true);

CREATE POLICY "Authenticated users can add comments"
  ON comments FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own comments"
  ON comments FOR UPDATE
  TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete own comments"
  ON comments FOR DELETE
  TO authenticated
  USING (auth.uid() = user_id);

CREATE POLICY "Admins can manage comments"
  ON comments FOR ALL
  TO authenticated
  USING (EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'));

-- =============================================
-- RECOMMENDATION_SIGNALS policies
-- =============================================
CREATE POLICY "Users can view own signals"
  ON recommendation_signals FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

CREATE POLICY "Users can insert signals"
  ON recommendation_signals FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

-- =============================================
-- ADMIN_AUDIT_LOG policies
-- =============================================
CREATE POLICY "Admins can read audit log"
  ON admin_audit_log FOR SELECT
  TO authenticated
  USING (EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "Admins can insert audit log"
  ON admin_audit_log FOR INSERT
  TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'));
