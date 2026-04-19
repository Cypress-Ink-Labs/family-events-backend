/*
  # Add missing foreign key indexes flagged by Supabase advisors

  These indexes cover foreign keys that currently force slower joins and
  parent-row updates/deletes.
*/

CREATE INDEX IF NOT EXISTS admin_audit_log_admin_user_id_idx
  ON public.admin_audit_log(admin_user_id);

CREATE INDEX IF NOT EXISTS comments_user_id_idx
  ON public.comments(user_id);

CREATE INDEX IF NOT EXISTS event_sources_city_id_idx
  ON public.event_sources(city_id);

CREATE INDEX IF NOT EXISTS events_source_id_idx
  ON public.events(source_id);

CREATE INDEX IF NOT EXISTS invite_codes_created_by_idx
  ON public.invite_codes(created_by);

CREATE INDEX IF NOT EXISTS pending_invite_claims_claimed_by_idx
  ON public.pending_invite_claims(claimed_by);

CREATE INDEX IF NOT EXISTS pending_invite_claims_invite_code_idx
  ON public.pending_invite_claims(invite_code);

CREATE INDEX IF NOT EXISTS recommendation_signals_event_id_idx
  ON public.recommendation_signals(event_id);

CREATE INDEX IF NOT EXISTS source_runs_source_id_idx
  ON public.source_runs(source_id);

CREATE INDEX IF NOT EXISTS user_calendar_events_event_id_idx
  ON public.user_calendar_events(event_id);

CREATE INDEX IF NOT EXISTS user_profiles_city_preference_id_idx
  ON public.user_profiles(city_preference_id);
