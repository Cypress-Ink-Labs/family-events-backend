# Semantic Search — `find_similar_events_by_id` RPC

> Verification completed: 2026-06-18 (plan 017). Local stack, 4 synthetic events.

## Overview

Vector-based "related events" search is backend-complete. The public
`find_similar_events_by_id` RPC is callable by `anon`, `authenticated`, and
`service_role` via the Supabase JavaScript client's `.rpc()` method (the anon
path was unblocked by plan 024 — see the security model below).

---

## Call shape (frontend)

```ts
const { data, error } = await supabase.rpc("find_similar_events_by_id", {
  p_event_id: eventId, // uuid — the source event
  p_limit: 5, // int  — max results (default 5); no server-side clamp — see below
  p_city_id: null, // uuid | null — restrict to same city (null = all cities)
});
```

All three parameters are optional (the function has defaults), but always pass
`p_event_id`. The function returns an empty array — not an error — when the
source event has no embedding.

---

## Return shape

| Column            | Type           | Notes                                                 |
| ----------------- | -------------- | ----------------------------------------------------- |
| `event_id`        | `uuid`         | Matching event ID                                     |
| `title`           | `text`         | Event title (public)                                  |
| `status`          | `event_status` | Always `'published'` — filter is enforced server-side |
| `cosine_distance` | `float8`       | `0` = identical, up to `0.3` (threshold)              |
| `source_id`       | `uuid \| null` | Upstream source ID                                    |
| `city_id`         | `uuid \| null` | City the event belongs to                             |

No PII, internal flags, or user data appear in the return set.

---

## Security model

```
public.find_similar_events_by_id   (SECURITY DEFINER, owner=postgres)
  └── private.find_similar_events_by_id  (SECURITY DEFINER, owner=postgres)
        └── private.find_similar_events  (SECURITY DEFINER, owner=postgres)
```

All three functions run as their owner (`postgres`). The public wrapper is a
pure pass-through (`SET search_path TO ''`, no dynamic SQL), so SECURITY DEFINER
only widens reachability of the private body — it does not bypass the
published-only filter enforced below.

Grants on `public.find_similar_events_by_id`:

```
anon          EXECUTE
authenticated EXECUTE
service_role  EXECUTE
```

**Published-only guarantee**: `private.find_similar_events_by_id` contains
`WHERE fse.status = 'published'::public.event_status` in its body. Because the
private body is `SECURITY DEFINER` (runs as `postgres`), the caller's role
cannot bypass this filter via RLS or grant escalation.

**Cosine-distance threshold**: `private.find_similar_events` rejects results
with `cosine_distance >= 0.3`. Only semantically close events are returned.

---

## Resolved: anon callers (SECURITY INVOKER mismatch)

**Status: RESOLVED in migration
`20260618000000_find_similar_events_by_id_security_definer.sql` (plan 024).**

Previously, `public.find_similar_events_by_id` was `SECURITY INVOKER`. When the
`anon` role called it, the wrapper executed as `anon` and then tried to invoke
`private.find_similar_events_by_id` — but `anon` has no `EXECUTE` on that private
function, so the call failed with
`{"code":"42501","message":"permission denied for function find_similar_events_by_id"}`
(verified via PostgREST HTTP with the publishable/anon key; `authenticated`
callers failed identically).

The wrapper is now `SECURITY DEFINER` + `SET search_path TO ''`, matching the
`private.invites_required` pattern: the wrapper runs as its owner (`postgres`),
which has `EXECUTE` on the private body, so `anon`/`authenticated` calls succeed.
The body remains a pure schema-qualified pass-through (no dynamic SQL, no
user-supplied identifiers), and the published-only filter still lives in the
private body — DEFINER widens reachability without weakening the guarantees.

Rollback (reintroduces the anon-block) lives at
`supabase/rollbacks/20260618000000_find_similar_events_by_id_security_definer_down.sql`.

---

## Known issue: `p_limit` unbounded

**Status: still open after plan 024.** The plan's optional `p_limit` clamp
(Step 4) was skipped because it requires a local Supabase to DB-verify a body
change, which was unavailable; shipping an unverified body change was out of
scope.

`p_limit` is passed raw to `LIMIT p_limit` with no server-side clamp. An anon
or authenticated caller can request arbitrarily many results. Recommended fix:
add `LEAST(p_limit, 50)` in `private.find_similar_events_by_id` before passing
to the inner query.

---

## Index usage (EXPLAIN ANALYZE)

Index: `event_embeddings_embedding_hnsw_idx` (HNSW, `vector_cosine_ops`, m=16,
ef_construction=64) on `public.event_embeddings`.

The similarity query uses this index:

```
Index Scan using event_embeddings_embedding_hnsw_idx on event_embeddings ee
  (cost=7.59..74.02 rows=216 width=48) (actual time=1.317..2.515 rows=3 loops=1)
  Order By: (embedding <=> p_embedding)
  Filter: (event_id <> p_exclude_event_id AND cosine_distance < 0.3)
```

Confirmed: **no full sequential scan** at the embedding layer. The events table
itself is a tiny Nested Loop (4 rows in test), which will also use its PK index
at production scale.

Note: HNSW approximate-NN does not guarantee exact threshold enforcement. The
`< p_threshold` filter is re-checked after the index scan (as shown in the
`Filter` line above). This is correct and expected behavior.

---

## HTTP wrapper decision

**No edge-function wrapper needed.** The frontend consumes this via
`.rpc("find_similar_events_by_id", …)` directly through PostgREST. There is no
server-side caching requirement or special HTTP shape that would justify a
wrapper. This decision holds now that the SECURITY INVOKER issue (above) is
fixed in migration `20260618000000_*` (plan 024).

---

## Embeddings pipeline

Embeddings are populated by:

- `embed-event` edge function (on-demand, triggered when an event is created/updated)
- `backfill-embeddings` cron (fills events missing embeddings)

Model: OpenAI `text-embedding-3-small` (1536 dimensions).
Table: `public.event_embeddings` (one row per event, RLS-protected).
