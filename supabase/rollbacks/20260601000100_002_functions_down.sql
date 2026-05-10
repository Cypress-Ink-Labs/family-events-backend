-- Rollback: drop all functions and triggers
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
DROP TRIGGER IF EXISTS events_search_vector_trigger ON public.events;
DROP TRIGGER IF EXISTS prevent_role_change_on_profile ON public.user_profiles;
DROP TRIGGER IF EXISTS reset_comment_approval_on_update ON public.comments;

DROP FUNCTION IF EXISTS public.reset_comment_approval_for_non_admin();
DROP FUNCTION IF EXISTS public.prevent_role_change();
DROP FUNCTION IF EXISTS public.claim_pending_invite_access();
DROP FUNCTION IF EXISTS public.redeem_invite_for_email(text, text);
DROP FUNCTION IF EXISTS public.redeem_invite(text);
DROP FUNCTION IF EXISTS public.run_due_source_scrapes();
DROP FUNCTION IF EXISTS public.invoke_scrape_source(uuid);
DROP FUNCTION IF EXISTS public.update_event_search_vector();
DROP FUNCTION IF EXISTS public.handle_new_user();
DROP FUNCTION IF EXISTS public.invites_required();
DROP FUNCTION IF EXISTS public.is_enabled_user();
DROP FUNCTION IF EXISTS private.bootstrap_admin();
DROP FUNCTION IF EXISTS private.current_profile_role();
DROP FUNCTION IF EXISTS private.has_enabled_access();
DROP FUNCTION IF EXISTS private.is_admin();
