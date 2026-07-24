# Plan 036: Bulk-hydrate memory-context reads

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving on. Honor STOP conditions — do not improvise. When done, update your row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 2f10101..HEAD -- supabase/functions/_shared/memory-context.ts supabase/functions/_shared/memory-context_test.ts`
> If either in-scope file changed since this plan was written, compare the "Current state" excerpts against the live code before proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none; land before plan 037 when possible
- **Category**: perf
- **Planned at**: commit `2f10101`, 2026-07-24

## Why this matters

`memory-context.ts` hydrates each similar event with two serial queries. Five tag-memory matches cost eleven database round trips; review memory costs fourteen in its current path. The tag queue processes four items concurrently, so one chunk can trigger roughly forty-four context round trips before any LLM work. Bulk-loading tags/events and decisions reduces each helper to one similarity RPC plus two reads, preserving public return shapes and ordering while cutting latency and connection pressure before plan 037 adds review-row concurrency.

## Current state

- `supabase/functions/_shared/memory-context.ts:101-155` loops over similar-event matches and awaits an `event_tags` query plus an `admin_event_decisions` query for each match.
- `fetchSimilarEventTagContext` sorts tags with admin overrides first, then confidence descending. It selects the latest relevant decision per event and emits contexts in similarity order.
- `memory-context.ts:181-235` similarly awaits one `events` query and one `admin_event_decisions` query per match in `fetchSimilarReviewContext`.
- Missing review event rows are skipped today. Preserve that behavior.
- The tag helper returns `[]` when no usable context exists. The review helper returns its existing empty-contexts/zero-adjustment object. Preserve both public signatures.
- Existing callers are `tag-event/handler.ts` and `process-event-review-queue/lib/worker.ts`. Plan 037 will parallelize review rows and should land after this N+1 reduction.
- `_shared/memory-context_test.ts` has the existing Supabase mock style. Extend its call tracking rather than replacing it.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Typecheck | `pnpm run check` | exit 0 |
| Guard tests | `pnpm run workspace:test` | all pass |
| Deno fn tests | `pnpm run test:deno` | all pass |
| vitest | `pnpm run test:functions` | all pass |
| Lint | `pnpm run lint` | exit 0 |
| DB tests (needs local DB) | `pnpm run db:start && pnpm run db:test` | all pass |

> **Local pnpm caveat**: pnpm scripts may fail locally on the documented supply-chain policy. If that occurs, run the corresponding oxlint, Deno, vitest, or Node binaries directly as documented in `plans/README.md`; do not treat the policy failure as a product test failure.

## Scope

**In scope** (the only files you should modify):
- `supabase/functions/_shared/memory-context.ts`
- `supabase/functions/_shared/memory-context_test.ts`

**Out of scope**:
- Public helper signatures or caller behavior
- Similarity RPC implementation or result limits
- The review worker's separate per-row flag, embedding, or city reads at approximately `worker.ts:421-452`; each is one query, not this N+1
- Review-queue concurrency; plan 037 owns it
- Database schema or migrations

## Git workflow

- Branch: `advisor/036-memory-context-bulk-hydration`
- Commit per logical unit using Conventional Commits, for example `perf(functions): bulk hydrate memory context`.
- Do NOT push or open a PR unless the operator instructs.

## Steps

### Step 1: Bulk-hydrate tag memory context

In `fetchSimilarEventTagContext`, keep the existing similarity RPC first. After successful matches:

1. Collect unique matched event IDs while preserving the original match list for output ordering.
2. Issue one `event_tags` query:
   ```ts
   .in("event_id", ids)
   .select("event_id, tag_id, confidence, is_manual_override, tags(slug, name)")
   ```
3. Issue one `admin_event_decisions` query:
   ```ts
   .in("event_id", ids)
   .in("decision_type", ["tag_edit", "status_and_tags"])
   .order("created_at", { ascending: false })
   ```
4. Group both result sets by `event_id` in Maps.
5. For each event, sort tags with the existing comparator: admin/manual override first, then confidence descending.
6. Because decisions are globally ordered newest-first, use the first grouped decision for each event.
7. Iterate the original similarity matches to assemble output so similarity order is unchanged.

On either bulk query error, emit one `logEdgeEvent("warn", …)` naming the failed bulk stage and return `[]`. This intentionally replaces partial per-event context with no-memory fallback; do not issue per-event retries.

**Verify**: a five-match unit test records exactly three Supabase calls: one similarity RPC, one bulk tag read, and one bulk decision read. Ordering and latest-decision assertions pass.

### Step 2: Bulk-hydrate review memory context

Apply the same shape in `fetchSimilarReviewContext`:

1. Keep the similarity RPC and collect unique event IDs.
2. Issue one `events` query selecting `id, status, llm_review_decision` with `.in("id", ids)`.
3. Issue one `admin_event_decisions` query filtered to `.eq("decision_type", "status_change")`, `.in("event_id", ids)`, and ordered by `created_at` descending.
4. Group rows by event ID. Use the first decision per event from the descending result.
5. Iterate similarity matches in their original order.
6. Skip matches whose event row is absent, matching today's `!eventRow → continue` behavior.

On either bulk query error, warn once and return the helper's existing empty-contexts/zero-adjustment result. Do not change confidence-adjustment calculations.

**Verify**: a five-match review-context test records exactly three Supabase calls; missing event rows are skipped; newest status-change decision wins per event.

### Step 3: Remove all per-match Supabase awaits

Delete the old per-match query blocks after the bulk implementations are green. Synchronous loops that group and assemble data are expected, but no `await supabase...` may remain inside a loop over similarity matches.

Do not introduce `Promise.all` per match; that reduces wall time but preserves the N+1 and multiplies connection pressure.

**Verify**: inspect every `for (const` loop in `memory-context.ts`; they perform only synchronous grouping/assembly. `grep -n "for (const" supabase/functions/_shared/memory-context.ts` may list loops, but none contains a Supabase await before its closing brace.

### Step 4: Add bulk-failure and ordering regressions

Extend `memory-context_test.ts` to cover both helpers:

- Five matches → exactly three Supabase calls per helper.
- Decisions for multiple events returned in mixed insertion order but descending `created_at` → newest per event selected.
- Tag sorting remains manual/admin override first, then confidence descending.
- Missing review event row → skipped without failure.
- Tag bulk query error and decision bulk query error → `[]` plus one warning each.
- Review events/decision bulk error → existing empty-contexts/zero-adjustment object plus one warning.
- Output contexts remain in similarity order even if bulk rows arrive in another order.

Use the existing log spy to assert one warning per failed bulk stage.

**Verify**: `pnpm run test:functions` → all memory-context regressions and existing shared-function tests pass.

### Step 5: Run full relevant gates

No DB migration is involved. Run shared-function tests, typecheck, and lint.

**Verify**: `pnpm run test:functions && pnpm run check && pnpm run lint` → all commands exit 0.

## Test plan

- Call-count tests enforce the optimization contract: exactly three Supabase operations for five matches in each helper.
- Ordering tests protect similarity order, tag precedence, and latest-decision selection.
- Missing-row behavior remains identical for review context.
- Error tests protect the deliberate all-or-nothing no-memory fallback and one-warning behavior.
- Existing public return-shape assertions remain unchanged.
- Final verification: vitest, typecheck, and lint all pass.

## Done criteria

- [ ] `fetchSimilarEventTagContext` performs one RPC plus two bulk reads regardless of match count.
- [ ] `fetchSimilarReviewContext` performs one RPC plus two bulk reads regardless of match count.
- [ ] No per-match Supabase await remains in `memory-context.ts`.
- [ ] Similarity ordering, tag sorting, latest-decision selection, and missing-event behavior are preserved.
- [ ] Any bulk-query error logs once and returns the helper's established empty fallback.
- [ ] Public signatures and caller code are unchanged.
- [ ] `pnpm run test:functions`, typecheck, and lint pass.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` row 036 is updated.

## STOP conditions

Stop and report back; do not improvise if:

- Either helper's public return shape or callers changed since `2f10101`.
- Supabase relation selection no longer returns `tags(slug, name)` in one bulk query.
- The existing logic intentionally preserves multiple decisions per event rather than only the latest.
- The change requires editing `tag-event/handler.ts`, review worker logic, or database schema.

## Maintenance notes

- Bulk-query failure now discards all context for that helper call instead of retaining partial per-event context. This is deliberate: memory is advisory, and one predictable no-memory path is safer than mixed partial state.
- Land this before plan 037 where possible; otherwise concurrent review rows multiply the current N+1 pressure.
- Keep call-count tests when adding new memory features. A fourth fixed bulk query may be justified, but per-match query growth is not.
- Reviewers should verify grouping Maps do not reorder similarity results or accidentally share mutable arrays across event IDs.
