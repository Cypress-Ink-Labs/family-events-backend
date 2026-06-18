# Plan 005: backfill-embeddings selects un-embedded events via a LEFT JOIN RPC

> **Executor instructions**: Follow step by step; run every verification command. Honor STOP
> conditions. Update this plan's row in `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 6c0db23..HEAD -- supabase/functions/backfill-embeddings supabase/migrations`

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW (behavior-preserving; new RPC + caller swap, with a paired rollback)
- **Depends on**: 001
- **Category**: perf
- **Planned at**: commit `6c0db23`, 2026-06-17

## Why this matters

`findEventsWithoutEmbeddings` loads **every** `event_embeddings.event_id`, then asks PostgREST to
exclude them with `.not("id", "in", "(id1,id2,...)")`. The exclusion list is serialized into the request
URL/filter. The code comment itself flags this as a scale problem ("For large sets this could be
slow… For production scale we'd use an RPC with a proper LEFT JOIN"). As the embedded set grows the
filter string grows unbounded — eventually it bloats request size, slows PostgREST parsing, and risks
hitting URL/statement limits. A single indexed `LEFT JOIN … WHERE ee.event_id IS NULL` RPC replaces it
with O(events) server-side work.

## Current state

`supabase/functions/backfill-embeddings/index.ts:31-65`:

```ts
async function findEventsWithoutEmbeddings(supabase: SupabaseClient, limit: number): Promise<EventRow[]> {
  // Supabase JS doesn't support LEFT JOIN directly, so we use a NOT IN subquery approach.
  const { data: embeddedIds, error: embError } = await supabase
    .from("event_embeddings").select("event_id");
  if (embError) throw embError;
  const excludeIds = (embeddedIds ?? []).map((row: { event_id: string }) => row.event_id);
  let query = supabase.from("events").select("id, title, description")
    .order("created_at", { ascending: true }).limit(limit);
  if (excludeIds.length > 0) {
    // For large sets this could be slow … For production scale we'd use an RPC with a proper LEFT JOIN.
    query = query.not("id", "in", `(${excludeIds.join(",")})`);
  }
  const { data, error } = await query;
  if (error) throw error;
  return (data ?? []) as EventRow[];
}
```

- `EventRow = { id: string; title: string; description: string | null }` (`index.ts:23-27`).
- `backfillEmbeddings(...)` is dependency-injectable (`fetchImpl`, `now`) and already has a vitest test
  `backfill-embeddings/index_test.ts` (Deno-style `*_test.ts`? confirm name; tests use a `FakeSupabase`).
- Migrations are append-only; every new migration needs a paired rollback in `supabase/rollbacks/`
  named `<timestamp>_*_down.sql` (`tests/guards/migration-rollbacks.test.mjs`). The latest migration is
  `20260601036000_*` plus a later `20260610162002_*`; pick a new timestamp strictly greater than the
  highest existing one. Look at a recent migration that creates a `SECURITY DEFINER` function with a
  `private` body + `public` wrapper for the house style, e.g.
  `supabase/migrations/20260601029000_find_similar_events_by_id.sql`.

## Steps

### Step 1: Add the RPC migration

Create `supabase/migrations/<new-ts>_list_events_needing_embeddings_rpc.sql` defining a function that
returns events lacking an embedding, ordered oldest-first, limited:

```sql
CREATE OR REPLACE FUNCTION public.list_events_needing_embeddings(p_limit int DEFAULT 50)
RETURNS TABLE (id uuid, title text, description text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $$
  SELECT e.id, e.title, e.description
  FROM public.events e
  LEFT JOIN public.event_embeddings ee ON ee.event_id = e.id
  WHERE ee.event_id IS NULL
  ORDER BY e.created_at ASC
  LIMIT GREATEST(1, LEAST(p_limit, 500));
$$;

REVOKE EXECUTE ON FUNCTION public.list_events_needing_embeddings(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_events_needing_embeddings(int) TO service_role;
```

Match the exact column types of `events.id/title/description` (verify against
`packages/contracts/src/database.types.ts` — `description` is nullable). Confirm an index exists on
`event_embeddings.event_id` (migration `20260601020000_event_embeddings_and_similarity.sql` should
declare one; if not, add it in this migration).

Create the paired rollback `supabase/rollbacks/<new-ts>_list_events_needing_embeddings_rpc_down.sql`:
```sql
DROP FUNCTION IF EXISTS public.list_events_needing_embeddings(int);
```

### Step 2: Swap the caller

Rewrite `findEventsWithoutEmbeddings` to call the RPC:

```ts
async function findEventsWithoutEmbeddings(supabase: SupabaseClient, limit: number): Promise<EventRow[]> {
  const { data, error } = await supabase.rpc("list_events_needing_embeddings", { p_limit: limit });
  if (error) throw error;
  return (data ?? []) as EventRow[];
}
```

### Step 3: Update tests

In `backfill-embeddings`'s existing test, update the `FakeSupabase` to stub `.rpc("list_events_needing_embeddings", ...)`
instead of the `.from("event_embeddings").select()` + `.not(...)` path. Add an assertion that the RPC is
called with `{ p_limit: <batchSize> }`. Keep the rest of the backfill behavior coverage intact.

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Typecheck | `pnpm run check` | exit 0 |
| Function tests | `pnpm -C supabase/functions exec vitest run backfill-embeddings` (or `deno test` if it's a `*_test.ts`) | pass |
| Rollback guard | `pnpm run workspace:test` | migration-rollbacks test passes (new migration is paired) |
| DB test (optional) | `pnpm run db:start && pnpm run db:test` | existing DB tests pass; type drift check still green |
| Regenerate types | `pnpm run db:types` then `git diff packages/contracts/src/database.types.ts` | new RPC appears; commit it |

## Done criteria

- [ ] New migration + paired `_down.sql` exist; `pnpm run workspace:test` passes
- [ ] `findEventsWithoutEmbeddings` calls `supabase.rpc("list_events_needing_embeddings", ...)` and no
      longer references `event_embeddings` directly or `.not("id", "in", ...)`
- [ ] `pnpm run check` exits 0
- [ ] backfill-embeddings tests pass with the RPC-based stub
- [ ] `packages/contracts/src/database.types.ts` regenerated to include the new RPC (no drift in CI)
- [ ] `plans/README.md` row for 005 updated

## STOP conditions

- The events/embeddings column types differ from the assumption (`description` not nullable, different
  PK type) — adjust the `RETURNS TABLE` to match and note it.
- `event_embeddings` has no index on `event_id` and you cannot confirm where to add it safely — report
  rather than guessing index placement.

## Maintenance notes

- Reviewer: confirm the RPC is `SECURITY DEFINER` with `search_path TO ''` and granted only to
  `service_role` (the function is invoked with the service-role client). Confirm the `LIMIT` is bounded.
- If pagination/resumability is later added to the backfill, the RPC's `ORDER BY created_at` is the
  stable cursor key — keep it.
