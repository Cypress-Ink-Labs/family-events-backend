drop policy "Admins can read event llm review queue" on "public"."event_llm_review_queue";

drop policy "Admins can read event llm review traces" on "public"."event_llm_review_traces";

revoke select on table "public"."event_tag_queue" from "anon";

revoke delete on table "public"."events" from "authenticated";

revoke insert on table "public"."events" from "authenticated";

revoke update on table "public"."events" from "authenticated";

revoke select on table "public"."favorites" from "anon";

revoke select on table "public"."ratings" from "anon";

revoke select on table "public"."source_scrape_queue" from "anon";

revoke select on table "public"."user_calendar_events" from "anon";

alter table "public"."event_sources" drop constraint "event_sources_scrape_interval_chk";

alter table "public"."events" drop constraint "events_age_range_chk";

alter table "public"."events" drop constraint "events_lat_lng_chk";

alter table "public"."events" drop constraint "events_price_chk";

alter table "public"."invite_codes" drop constraint "invite_codes_used_count_max_chk";

alter table "public"."user_profiles" drop constraint "user_profiles_child_age_chk";

drop function if exists "private"."public_event_image_attributions"(p_event_id uuid);

drop index if exists "public"."events_published_city_start_datetime_idx";

drop index if exists "public"."recommendation_signals_user_id_idx";

drop index if exists "public"."user_calendar_events_user_id_idx";

CREATE INDEX event_ai_traces_created_at_idx ON public.event_ai_traces USING btree (created_at);

CREATE INDEX event_llm_review_queue_source_id_idx ON public.event_llm_review_queue USING btree (source_id) WHERE (source_id IS NOT NULL);

CREATE INDEX event_llm_review_queue_source_run_id_idx ON public.event_llm_review_queue USING btree (source_run_id) WHERE (source_run_id IS NOT NULL);

CREATE INDEX event_llm_review_traces_queue_id_idx ON public.event_llm_review_traces USING btree (queue_id) WHERE (queue_id IS NOT NULL);

CREATE INDEX event_llm_review_traces_source_id_idx ON public.event_llm_review_traces USING btree (source_id) WHERE (source_id IS NOT NULL);

CREATE INDEX event_llm_review_traces_source_run_id_idx ON public.event_llm_review_traces USING btree (source_run_id) WHERE (source_run_id IS NOT NULL);

CREATE INDEX events_needing_enrichment_created_idx ON public.events USING btree (created_at DESC, id) WHERE ((latitude IS NULL) OR (longitude IS NULL) OR (images = '[]'::jsonb) OR (jsonb_array_length(images) = 0));

CREATE INDEX invite_redemption_attempts_attempted_at_idx ON public.invite_redemption_attempts USING btree (attempted_at);

CREATE INDEX invite_request_attempts_attempted_at_idx ON public.invite_request_attempts USING btree (attempted_at);

CREATE INDEX recommendation_signals_created_at_idx ON public.recommendation_signals USING btree (created_at);

CREATE INDEX source_extraction_traces_created_at_idx ON public.source_extraction_traces USING btree (created_at);

CREATE INDEX source_runs_running_started_idx ON public.source_runs USING btree (started_at) WHERE (status = 'running'::text);

CREATE INDEX source_runs_started_at_idx1 ON public.source_runs USING btree (started_at);

CREATE INDEX source_scrape_queue_finished_at_idx ON public.source_scrape_queue USING btree (finished_at);

alter table "public"."event_llm_review_queue" add constraint "event_llm_review_queue_trigger_type_check" CHECK ((trigger_type = ANY (ARRAY['import'::text, 'reclassify'::text, 'manual-review'::text]))) not valid;

alter table "public"."event_llm_review_queue" validate constraint "event_llm_review_queue_trigger_type_check";

alter table "public"."event_sources" add constraint "event_sources_scrape_interval_chk" CHECK (((scrape_interval_hours >= 1) AND (scrape_interval_hours <= 720))) not valid;

alter table "public"."event_sources" validate constraint "event_sources_scrape_interval_chk";

alter table "public"."events" add constraint "events_age_range_chk" CHECK ((((age_min IS NULL) OR (age_min >= 0)) AND ((age_max IS NULL) OR (age_max >= 0)) AND ((age_min IS NULL) OR (age_max IS NULL) OR (age_min <= age_max)))) not valid;

alter table "public"."events" validate constraint "events_age_range_chk";

alter table "public"."events" add constraint "events_lat_lng_chk" CHECK ((((latitude IS NULL) OR ((latitude >= ('-90'::integer)::numeric) AND (latitude <= (90)::numeric))) AND ((longitude IS NULL) OR ((longitude >= ('-180'::integer)::numeric) AND (longitude <= (180)::numeric))))) not valid;

alter table "public"."events" validate constraint "events_lat_lng_chk";

alter table "public"."events" add constraint "events_price_chk" CHECK (((price IS NULL) OR (price >= (0)::numeric))) not valid;

alter table "public"."events" validate constraint "events_price_chk";

alter table "public"."invite_codes" add constraint "invite_codes_used_count_max_chk" CHECK ((used_count <= max_uses)) not valid;

alter table "public"."invite_codes" validate constraint "invite_codes_used_count_max_chk";

alter table "public"."user_profiles" add constraint "user_profiles_child_age_chk" CHECK (((child_age IS NULL) OR ((child_age >= 0) AND (child_age <= 18)))) not valid;

alter table "public"."user_profiles" validate constraint "user_profiles_child_age_chk";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.admin_railway_cron_run_history(p_label text DEFAULT NULL::text, p_limit integer DEFAULT 50)
 RETURNS TABLE(id bigint, label text, status text, http_status integer, duration_s integer, body text, ran_at timestamp with time zone)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  SELECT *
  FROM private.admin_railway_cron_run_history(p_label, p_limit);
$function$
;

CREATE OR REPLACE FUNCTION public.is_enabled_user()
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  SELECT private.has_enabled_access();
$function$
;

grant update on table "public"."user_profiles" to "authenticated";


  create policy "Admins can read event llm review queue"
  on "public"."event_llm_review_queue"
  as permissive
  for select
  to authenticated
using (( SELECT private.is_admin() AS is_admin));



  create policy "Admins can read event llm review traces"
  on "public"."event_llm_review_traces"
  as permissive
  for select
  to authenticated
using (( SELECT private.is_admin() AS is_admin));



