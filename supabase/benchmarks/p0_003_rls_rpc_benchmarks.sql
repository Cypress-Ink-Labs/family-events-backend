\set ON_ERROR_STOP on
\if :{?benchmark_label}
\else
\set benchmark_label manual
\endif

\pset pager off
\timing on

\echo == P0-003 RLS/RPC benchmark :benchmark_label ==
SELECT
  now() AS captured_at,
  current_setting('server_version') AS postgres_version,
  current_database() AS database_name;

BEGIN;

SET LOCAL client_min_messages = warning;
SET LOCAL jit = off;
SET LOCAL timezone = 'UTC';

CREATE TEMP TABLE p0_bench_context (
  city_id uuid NOT NULL,
  alt_city_id uuid NOT NULL,
  user_id uuid NOT NULL,
  event_id uuid
) ON COMMIT DROP;

INSERT INTO p0_bench_context (city_id, alt_city_id, user_id)
VALUES (gen_random_uuid(), gen_random_uuid(), gen_random_uuid());

INSERT INTO auth.users (
  id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  raw_app_meta_data,
  raw_user_meta_data,
  created_at,
  updated_at
)
SELECT
  user_id,
  'authenticated',
  'authenticated',
  'p0-003-bench@example.invalid',
  '',
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{}'::jsonb,
  now(),
  now()
FROM p0_bench_context;

INSERT INTO public.cities (id, name, slug, is_active, timezone)
SELECT city_id, 'P0 Benchmark City', 'p0-benchmark-city', true, 'America/Chicago'
FROM p0_bench_context
UNION ALL
SELECT alt_city_id, 'P0 Benchmark Alt City', 'p0-benchmark-alt-city', true, 'America/Chicago'
FROM p0_bench_context;

INSERT INTO public.user_profiles (id, email, role, city_preference_id)
SELECT user_id, 'p0-003-bench@example.invalid', 'user', city_id
FROM p0_bench_context
ON CONFLICT (id) DO UPDATE
SET
  email = EXCLUDED.email,
  role = EXCLUDED.role,
  city_preference_id = EXCLUDED.city_preference_id;

INSERT INTO public.user_access (user_id, is_enabled, enabled_at)
SELECT user_id, true, now()
FROM p0_bench_context
ON CONFLICT (user_id) DO UPDATE
SET
  is_enabled = EXCLUDED.is_enabled,
  enabled_at = EXCLUDED.enabled_at;

CREATE TEMP TABLE p0_bench_tags (
  id uuid PRIMARY KEY,
  slug text NOT NULL
) ON COMMIT DROP;

WITH inserted AS (
  INSERT INTO public.tags (id, name, slug, color, category)
  SELECT id, name, slug, color, 'theme'
  FROM (
    VALUES
      (gen_random_uuid(), 'P0 Sports', 'p0-sports', '#2563eb'),
      (gen_random_uuid(), 'P0 Art', 'p0-art', '#dc2626'),
      (gen_random_uuid(), 'P0 Outdoor', 'p0-outdoor', '#16a34a')
  ) AS t(id, name, slug, color)
  RETURNING id, slug
)
INSERT INTO p0_bench_tags (id, slug)
SELECT id, slug
FROM inserted;

CREATE TEMP TABLE p0_bench_events AS
SELECT
  gen_random_uuid() AS id,
  g AS seq,
  CASE WHEN g % 5 = 0 THEN c.alt_city_id ELSE c.city_id END AS city_id,
  CASE WHEN g % 7 = 0 THEN 'draft' ELSE 'published' END AS status,
  (date_trunc('day', now()) + ((g % 45) - 7) * interval '1 day' + ((g % 12) * interval '1 hour'))::timestamptz AS start_datetime
FROM generate_series(1, 12000) AS g
CROSS JOIN p0_bench_context AS c;

INSERT INTO public.events (
  id,
  title,
  description,
  start_datetime,
  end_datetime,
  timezone,
  venue_name,
  address,
  city_id,
  latitude,
  longitude,
  age_min,
  age_max,
  price,
  is_free,
  source_url,
  source_name,
  status,
  is_featured,
  is_outdoor,
  ai_confidence,
  created_at,
  updated_at
)
SELECT
  id,
  'P0 Benchmark Event ' || seq,
  'Synthetic event row for repeatable P0-003 query-plan baselines',
  start_datetime,
  start_datetime + interval '2 hours',
  'America/Chicago',
  'P0 Benchmark Venue',
  '1 Benchmark Way',
  city_id,
  41.8781 + ((seq % 100)::numeric / 10000),
  -87.6298 - ((seq % 100)::numeric / 10000),
  CASE WHEN seq % 3 = 0 THEN 3 ELSE NULL END,
  CASE WHEN seq % 4 = 0 THEN 10 ELSE NULL END,
  CASE WHEN seq % 2 = 0 THEN 0 ELSE 12 END,
  seq % 2 = 0,
  'https://example.invalid/p0/' || seq,
  'P0-003 benchmark',
  status,
  seq % 11 = 0,
  seq % 2 = 0,
  0.95,
  now(),
  now()
FROM p0_bench_events;

UPDATE p0_bench_context
SET event_id = (
  SELECT id
  FROM p0_bench_events
  WHERE status = 'published'
    AND seq % 22 = 0
  ORDER BY seq
  LIMIT 1
);

INSERT INTO public.event_tags (event_id, tag_id, confidence)
SELECT e.id, t.id, 1
FROM p0_bench_events e
JOIN p0_bench_tags t
  ON (t.slug = 'p0-sports' AND e.seq % 2 = 0)
  OR (t.slug = 'p0-art' AND e.seq % 3 = 0)
  OR (t.slug = 'p0-outdoor' AND e.seq % 5 = 0);

INSERT INTO public.favorites (user_id, event_id)
SELECT c.user_id, e.id
FROM p0_bench_events e
CROSS JOIN p0_bench_context c
WHERE e.status = 'published'
  AND e.seq % 19 = 0;

INSERT INTO public.user_calendar_events (user_id, event_id)
SELECT c.user_id, e.id
FROM p0_bench_events e
CROSS JOIN p0_bench_context c
WHERE e.status = 'published'
  AND e.seq % 23 = 0;

INSERT INTO public.ratings (user_id, event_id, score)
SELECT c.user_id, e.id, ((e.seq % 5) + 1)
FROM p0_bench_events e
CROSS JOIN p0_bench_context c
WHERE e.status = 'published'
  AND e.seq % 13 = 0;

INSERT INTO public.comments (user_id, event_id, body, is_approved, is_flagged, created_at, updated_at)
SELECT
  c.user_id,
  e.id,
  'Benchmark comment ' || e.seq,
  e.seq % 17 <> 0,
  false,
  now() - (e.seq % 30) * interval '1 minute',
  now()
FROM p0_bench_events e
CROSS JOIN p0_bench_context c
WHERE e.status = 'published'
  AND e.seq % 11 = 0;

ANALYZE public.events;
ANALYZE public.event_tags;
ANALYZE public.favorites;
ANALYZE public.user_calendar_events;
ANALYZE public.ratings;
ANALYZE public.comments;

GRANT SELECT ON p0_bench_context TO anon, authenticated;
GRANT SELECT ON p0_bench_events TO anon, authenticated;
GRANT SELECT ON p0_bench_tags TO anon, authenticated;

\echo == dataset ==
SELECT
  (SELECT count(*) FROM p0_bench_events) AS events,
  (SELECT count(*) FROM public.event_tags et JOIN p0_bench_events e ON e.id = et.event_id) AS event_tags,
  (SELECT count(*) FROM public.ratings r JOIN p0_bench_events e ON e.id = r.event_id) AS ratings,
  (SELECT count(*) FROM public.comments c JOIN p0_bench_events e ON e.id = c.event_id) AS comments;

\echo == events_enriched: authenticated city/date list ==
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM p0_bench_context), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
\echo == events_enriched body: authenticated representative plan ==
EXPLAIN (ANALYZE, BUFFERS)
SELECT
  e.id,
  e.title,
  e.start_datetime,
  COALESCE(rs.avg_score, 0)::numeric AS avg_rating,
  COALESCE(rs.rating_count, 0)::int AS rating_count,
  COALESCE(ts.tags, '[]'::jsonb) AS tags,
  (f.event_id IS NOT NULL) AS is_favorited,
  (c.event_id IS NOT NULL) AS is_in_calendar
FROM public.events e
LEFT JOIN LATERAL (
  SELECT ROUND(AVG(r.score)::numeric, 1) AS avg_score,
         COUNT(*)::int AS rating_count
  FROM public.ratings r
  WHERE r.event_id = e.id
) rs ON TRUE
LEFT JOIN LATERAL (
  SELECT jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'slug', t.slug, 'color', t.color) ORDER BY t.name) AS tags
  FROM public.event_tags et
  JOIN public.tags t ON t.id = et.tag_id
  WHERE et.event_id = e.id
) ts ON TRUE
LEFT JOIN public.favorites f
  ON f.event_id = e.id AND f.user_id = (SELECT user_id FROM p0_bench_context)
LEFT JOIN public.user_calendar_events c
  ON c.event_id = e.id AND c.user_id = (SELECT user_id FROM p0_bench_context)
WHERE e.start_datetime >= (date_trunc('day', now()) - interval '1 day')::timestamptz
  AND e.start_datetime <= (date_trunc('day', now()) + interval '14 days')::timestamptz
  AND e.status = 'published'
  AND e.city_id = (SELECT city_id FROM p0_bench_context)
ORDER BY e.start_datetime ASC
LIMIT 50;

EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM public.events_enriched(
  (SELECT city_id FROM p0_bench_context),
  'published',
  50,
  0,
  (SELECT user_id FROM p0_bench_context),
  NULL,
  (date_trunc('day', now()) - interval '1 day')::timestamptz,
  (date_trunc('day', now()) + interval '14 days')::timestamptz
);

\echo == search_events: authenticated filters + tag AND ==
\echo == search_events body: authenticated representative plan ==
EXPLAIN (ANALYZE, BUFFERS)
SELECT e.*
FROM public.events e
WHERE e.status = 'published'
  AND e.city_id = (SELECT city_id FROM p0_bench_context)
  AND e.start_datetime >= (date_trunc('day', now()) - interval '1 day')::timestamptz
  AND e.start_datetime <= (date_trunc('day', now()) + interval '14 days')::timestamptz
  AND e.is_free = true
  AND COALESCE(e.age_max, 99) >= 4
  AND COALESCE(e.age_min, 0) <= 9
  AND (
    e.title ILIKE '%Benchmark%'
    OR e.description ILIKE '%Benchmark%'
  )
  AND (
    SELECT COUNT(DISTINCT t.slug)
    FROM public.event_tags et
    JOIN public.tags t ON t.id = et.tag_id
    WHERE et.event_id = e.id
      AND t.slug = ANY(ARRAY['p0-sports', 'p0-art'])
  ) = 2
ORDER BY e.start_datetime ASC
LIMIT 50;

EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM public.search_events(
  (SELECT city_id FROM p0_bench_context),
  (date_trunc('day', now()) - interval '1 day')::timestamptz,
  (date_trunc('day', now()) + interval '14 days')::timestamptz,
  4,
  9,
  true,
  NULL,
  ARRAY['p0-sports', 'p0-art'],
  'Benchmark',
  'published',
  50,
  0
);

\echo == plan_events_first_nonempty_window: authenticated scoring ==
\echo == plan_events candidate body: authenticated representative plan ==
EXPLAIN (ANALYZE, BUFFERS)
SELECT e.id, e.age_min, e.age_max, e.latitude, e.longitude, e.is_outdoor
FROM public.events e
WHERE e.status = 'published'
  AND e.city_id = (SELECT city_id FROM p0_bench_context)
  AND (e.start_datetime AT TIME ZONE e.timezone)::date = (now() AT TIME ZONE 'America/Chicago')::date;

\echo == plan_events candidate body: authenticated no-city fallback ==
EXPLAIN (ANALYZE, BUFFERS)
SELECT e.id, e.age_min, e.age_max, e.latitude, e.longitude, e.is_outdoor
FROM public.events e
WHERE e.status = 'published'
  AND (e.start_datetime AT TIME ZONE e.timezone)::date = (now() AT TIME ZONE 'America/Chicago')::date;

EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM public.plan_events_first_nonempty_window(
  (SELECT user_id FROM p0_bench_context),
  (now() AT TIME ZONE 'America/Chicago')::date,
  (SELECT city_id FROM p0_bench_context),
  41.8781,
  -87.6298,
  6,
  'outdoor',
  3,
  7
);

\echo == public_events: anon city/date view ==
SET LOCAL ROLE anon;
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM public.public_events
WHERE city_id = (SELECT city_id FROM p0_bench_context)
  AND start_datetime >= (date_trunc('day', now()) - interval '1 day')::timestamptz
  AND start_datetime <= (date_trunc('day', now()) + interval '14 days')::timestamptz
ORDER BY start_datetime ASC
LIMIT 50;

\echo == comments: anon approved comments by event ==
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, user_id, event_id, body, is_approved, is_flagged, created_at, updated_at
FROM public.comments
WHERE event_id = (SELECT event_id FROM p0_bench_context)
  AND is_approved = true
ORDER BY created_at DESC
LIMIT 25;

\echo == event_tags: anon tags by event ==
EXPLAIN (ANALYZE, BUFFERS)
SELECT et.event_id, et.tag_id, t.slug
FROM public.event_tags et
JOIN public.tags t ON t.id = et.tag_id
WHERE et.event_id = (SELECT event_id FROM p0_bench_context)
ORDER BY t.slug;

ROLLBACK;
