/*
  # Saturday Plan lane A: schema + public view + planning RPC

  Adds:
  - cube / earthdistance extensions
  - events.is_outdoor (boolean) + one-time backfill from existing tags
  - public_events view (whitelisted, published-only) + anon SELECT grant
  - plan_events_for_user RPC (grouped aggregate join for history affinity)

  IMPORTANT:
  - raw anon SELECT on public.events is explicitly removed
  - share previews should read public.public_events, not public.events

  Score composition (decision 12A + ASCII requirement):

    +--------------------------------------------------------------+
    | composite_score = distance*0.40 + weather*0.25              |
    |                   + age*0.20 + history_affinity*0.15        |
    +--------------------------------------------------------------+
              |                |                |          |
              |                |                |          +-- tag overlap with
              |                |                |              user's favorite tags
              |                |                +------------- child_age fit against
              |                |                               event age_min/age_max
              |                +------------------------------ weather_fit preference
              +----------------------------------------------- geo distance fit
*/

create extension if not exists cube with schema public;
create extension if not exists earthdistance with schema public;

alter table public.events
  add column if not exists is_outdoor boolean;

with tag_inference as (
  select
    et.event_id,
    bool_or(t.slug in ('outdoor', 'park', 'nature', 'hike', 'playground')) as has_outdoor_signal,
    bool_or(t.slug in ('indoor', 'museum', 'library', 'theater')) as has_indoor_signal
  from public.event_tags et
  join public.tags t on t.id = et.tag_id
  group by et.event_id
)
update public.events e
set is_outdoor = case
  when ti.has_outdoor_signal and not ti.has_indoor_signal then true
  when ti.has_indoor_signal and not ti.has_outdoor_signal then false
  else null
end
from tag_inference ti
where e.id = ti.event_id
  and e.is_outdoor is null;

drop view if exists public.public_events;
create view public.public_events as
select
  e.id,
  e.title,
  e.description,
  e.start_datetime,
  e.end_datetime,
  e.venue_name,
  e.address,
  e.city_id,
  e.images,
  e.price,
  e.is_free,
  e.source_url
from public.events e
where e.status = 'published';

grant select on public.public_events to anon;

drop policy if exists "Anon can read published events" on public.events;
drop policy if exists "Published events are public" on public.events;

create or replace function public.plan_events_for_user(
  p_user_id uuid,
  p_date date default (now() at time zone 'utc')::date,
  p_city_id uuid default null,
  p_lat double precision default null,
  p_lng double precision default null,
  p_kid_age integer default null,
  p_weather_fit text default 'neutral',
  p_limit integer default 3
)
returns table (
  event_id uuid,
  score numeric,
  distance_score numeric,
  weather_score numeric,
  age_score numeric,
  history_affinity numeric,
  distance_km numeric
)
language sql
stable
set search_path = ''
as $$
  with user_favorite_tags as (
    select et.tag_id
    from public.favorites f
    join public.event_tags et on et.event_id = f.event_id
    where f.user_id = p_user_id
    group by et.tag_id
  ),
  candidate_events as (
    select
      e.id,
      e.age_min,
      e.age_max,
      e.latitude,
      e.longitude,
      e.is_outdoor
    from public.events e
    where e.status = 'published'
      and (p_city_id is null or e.city_id = p_city_id)
      and e.start_datetime::date = p_date
  ),
  scored_events as (
    select
      e.id as event_id,
      case
        when p_lat is null
          or p_lng is null
          or e.latitude is null
          or e.longitude is null
          then null
        else public.earth_distance(
          public.ll_to_earth(p_lat, p_lng),
          public.ll_to_earth(e.latitude, e.longitude)
        ) / 1000.0
      end as distance_km,
      case
        when p_lat is null
          or p_lng is null
          or e.latitude is null
          or e.longitude is null
          then 0.50
        else greatest(0.0, 1.0 - least(
          public.earth_distance(
            public.ll_to_earth(p_lat, p_lng),
            public.ll_to_earth(e.latitude, e.longitude)
          ) / 1000.0,
          50.0
        ) / 50.0)
      end as distance_score,
      case lower(coalesce(p_weather_fit, 'neutral'))
        when 'outdoor' then case when e.is_outdoor is true then 1.0 else 0.0 end
        when 'indoor' then case when e.is_outdoor is false then 1.0 else 0.0 end
        else 0.50
      end as weather_score,
      case
        when p_kid_age is null then 0.50
        when e.age_min is null and e.age_max is null then 0.50
        when p_kid_age between coalesce(e.age_min, p_kid_age) and coalesce(e.age_max, p_kid_age) then 1.0
        else 0.0
      end as age_score,
      coalesce(history.history_affinity, 0.0) as history_affinity
    from candidate_events e
    left join lateral (
      select
        case
          when count(et.tag_id) = 0 then 0.0
          else count(et.tag_id) filter (where uft.tag_id is not null)::numeric
            / count(et.tag_id)::numeric
        end as history_affinity
      from public.event_tags et
      left join user_favorite_tags uft on uft.tag_id = et.tag_id
      where et.event_id = e.id
    ) as history on true
  )
  select
    se.event_id,
    round((se.distance_score * 0.40 + se.weather_score * 0.25 + se.age_score * 0.20 + se.history_affinity * 0.15)::numeric, 6) as score,
    round(se.distance_score::numeric, 6) as distance_score,
    round(se.weather_score::numeric, 6) as weather_score,
    round(se.age_score::numeric, 6) as age_score,
    round(se.history_affinity::numeric, 6) as history_affinity,
    case when se.distance_km is null then null else round(se.distance_km::numeric, 3) end as distance_km
  from scored_events se
  order by score desc, distance_km asc nulls last, event_id asc
  limit greatest(coalesce(p_limit, 3), 1);
$$;

grant execute on function public.plan_events_for_user(
  uuid,
  date,
  uuid,
  double precision,
  double precision,
  integer,
  text,
  integer
) to authenticated;
