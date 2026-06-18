# Plan 017 (spike): Verify and document the public semantic-search RPC surface

> **Executor instructions**: SPIKE plan — mostly verification + documentation, with an optional thin
> wrapper only if a decision calls for it. Record findings. Update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 6c0db23..HEAD -- supabase/migrations/20260601029000_find_similar_events_by_id.sql supabase/migrations/20260601020000_event_embeddings_and_similarity.sql`

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: direction
- **Planned at**: commit `6c0db23`, 2026-06-17

## Why this matters (product) — and a correction

The audit initially framed "semantic search" as an unbuilt feature. **That's wrong** — the backend is
already done and already public:

- `public.find_similar_events_by_id(p_event_id, p_limit, p_city_id)` exists and is
  `GRANT EXECUTE ... TO authenticated, anon, service_role`
  (`supabase/migrations/20260601029000_find_similar_events_by_id.sql:84-85`). It returns only `published`
  events and excludes the source event.
- Embeddings are populated by `embed-event` + the `backfill-embeddings` cron into `event_embeddings`.

So the data + access layer for "related events" / "people who liked X" is shippable today via a PostgREST
`.rpc("find_similar_events_by_id", …)` call. The remaining work is **frontend** (out of this repo) plus a
backend verification/documentation pass so whoever builds the UI can trust the surface. This spike does the
backend half honestly instead of rebuilding what exists.

## Current state

- `private.find_similar_events_by_id` (SECURITY DEFINER, `service_role` only) does the embedding lookup +
  delegates to `private.find_similar_events(p_threshold := 0.3, …)`, filtering `status = 'published'`.
- `public.find_similar_events_by_id` (SECURITY INVOKER) wraps it and is granted to `anon, authenticated, service_role`.
- Returns: `event_id, title, status, cosine_distance, source_id, city_id`.
- Index: `20260601020000_event_embeddings_and_similarity.sql` should define the vector index used by
  `private.find_similar_events` — verify it (ivfflat/hnsw) and that the similarity query uses it.

## Steps

### Step 1: Confirm reachability via PostgREST as `anon`

With a local stack (`pnpm run db:start`), seed a couple of published events + embeddings (or use existing
fixtures), then call the RPC as the `anon` role and confirm it returns rows and does NOT leak non-published
events. Document the exact call shape the frontend should use:

```
supabase.rpc("find_similar_events_by_id", { p_event_id: "<uuid>", p_limit: 5, p_city_id: null })
```

### Step 2: Verify index usage (perf)

`EXPLAIN ANALYZE` the underlying `private.find_similar_events` similarity query against a non-trivial row
count. Confirm it uses the vector index, not a full scan. Record the plan. If it seq-scans, note the index
name/params to fix (that becomes a follow-up perf finding, not part of this spike).

### Step 3: Confirm safety properties

- Only `published` events returned (the private body filters; confirm the public wrapper can't bypass it).
- `p_limit` is bounded (check `private.find_similar_events` clamps limit; if unbounded, note it — an anon
  caller could request a huge limit).
- No PII / internal fields in the return shape (it returns ids + title + distance — confirm).

### Step 4: Document

Add a short section to the new `README.md`/`CLAUDE.md` (plan 003) or `supabase/docs/` describing:
the RPC, its grants, the call shape, return columns, the published-only guarantee, and the limit bound.
This is the deliverable the frontend team consumes.

### Step 5 (optional, only if decided): thin HTTP wrapper

The project's pattern is PostgREST `.rpc()` from the client, so an edge-function wrapper is likely
unnecessary. Build a `related-events` edge function **only if** Step 1 reveals the frontend cannot call the
RPC directly (e.g. it needs server-side caching or a public-no-auth HTTP shape like `share-og`). If so,
model it on `share-og` (public GET, cache headers, UUID validation) and register it (config.toml +
deploy.config.json). Otherwise record "no wrapper needed" and stop.

## Commands you will need

| Purpose          | Command                                                                              | Expected             |
| ---------------- | ------------------------------------------------------------------------------------ | -------------------- |
| Local DB         | `pnpm run db:start`                                                                  | up                   |
| Call RPC as anon | `psql`/PostgREST with anon role, or supabase-js with anon key                        | rows; published-only |
| Explain          | `psql "$DB_URL" -c "EXPLAIN ANALYZE SELECT * FROM private.find_similar_events(...)"` | index scan           |

## Deliverable / Done criteria

- [ ] Confirmed: `anon` can call `public.find_similar_events_by_id` and gets only published events
- [ ] `EXPLAIN ANALYZE` recorded; index usage confirmed (or a follow-up filed if not)
- [ ] Limit bound + return-shape safety confirmed (or gaps noted)
- [ ] A doc section describing the RPC + the exact frontend call shape exists
- [ ] Decision recorded: HTTP wrapper needed? (default: no)
- [ ] `plans/README.md` row for 017 updated

## STOP conditions

- The similarity query seq-scans on realistic data — record it as a separate perf follow-up; don't tune
  the index inside this spike unless it's a one-line fix.
- `p_limit` is unbounded for anon — flag as a small security follow-up (clamp it) rather than fixing here,
  unless trivial.

## Maintenance notes

- The honest framing: this feature is _backend-complete_; the value is unblocking the frontend with a
  trustworthy, documented surface. Don't rebuild it.
