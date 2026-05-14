-- Account deletion RPC for consumer apps (web + iOS).
--
-- Pattern: SECURITY DEFINER body lives in `private`; a thin SECURITY INVOKER
-- wrapper in `public` calls into it. Anon callers are denied.
--
-- Behavior:
--   Deletes the auth.users row for the calling user. All per-user data is
--   cleaned up automatically via ON DELETE CASCADE chains:
--     auth.users → public.user_profiles (ON DELETE CASCADE)
--       → public.favorites             (ON DELETE CASCADE)
--       → public.ratings               (ON DELETE CASCADE)
--       → public.comments              (ON DELETE CASCADE)
--       → public.user_calendar_events  (ON DELETE CASCADE)
--   auth.identities, auth.sessions, and auth.refresh_tokens are also
--   cascaded by Supabase internally.
--
-- Note: the plan assumed table names user_event_favorites, user_event_ratings,
-- user_event_comments, user_plan_events — none of these exist. The actual
-- tables (favorites, ratings, comments, user_calendar_events) are all covered
-- by the cascade above, so no explicit per-table deletes are needed.
--
-- Supabase requires service_role to delete auth.users, hence SECURITY DEFINER.

set check_function_bodies = off;

create or replace function private.delete_my_account()
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
    v_user_id uuid := auth.uid();
begin
    if v_user_id is null then
        raise exception 'not authenticated' using errcode = '28000';
    end if;

    -- The auth.users row itself. ON DELETE CASCADE handles all child rows:
    --   auth.identities, auth.sessions, auth.refresh_tokens,
    --   public.user_profiles, and all tables that cascade from user_profiles
    --   (favorites, ratings, comments, user_calendar_events).
    delete from auth.users where id = v_user_id;
end;
$$;

grant execute on function private.delete_my_account() to authenticated, service_role;

create or replace function public.delete_my_account()
returns void
language sql
security invoker
set search_path = pg_catalog, public
as $$
    select private.delete_my_account();
$$;

revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

comment on function public.delete_my_account() is
    'Deletes the calling user''s account and per-user app data. ' ||
    'Anon-callable: NO. Used by web /profile and iOS Profile sheet.';
