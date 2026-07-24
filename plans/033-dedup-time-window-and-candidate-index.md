# Plan 033: Enforce a per-pair dedup window and pre-index candidates

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving on. Honor STOP conditions — do not improvise. When done, update your row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 2f10101..HEAD -- supabase/functions/_shared/dedup-utils.ts supabase/functions/_shared/dedup-utils_test.ts supabase/functions/scrape-source/lib/process-source.ts supabase/functions/scrape-source/lib/process-source_test.ts`
> If any in-scope file changed since this plan was written, compare the "Current state" excerpts against the live code before proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: bug + perf
- **Planned at**: commit `2f10101`, 2026-07-24

## Why this matters

Cross-source fuzzy dedup uses one broad window for an entire scrape batch, then compares titles without a per-pair time check. In a multi-day batch, recurring events such as weekly “Family Storytime” can suppress each other even when they are days apart, causing permanent data loss. The candidate RPC also defaults to 500 rows, and the current nested scan repeatedly canonicalizes titles and allocates token sets, producing roughly 302,000 comparisons and 605,000 transient sets for a documented 605-event batch. Enforcing the ±4-hour rule in the shared predicate and pre-indexing candidates preserves intended dedup semantics while cutting hot-path CPU and allocation pressure.

## Current state

- `supabase/functions/scrape-source/lib/process-source.ts:237-247` derives one candidate range from the batch minimum minus four hours through batch maximum plus four hours.
- `supabase/functions/_shared/dedup-utils.ts:100-108` accepts Jaccard similarity ≥ 0.7 without comparing the candidate and existing event start times. Its comment incorrectly claims the RPC already bounds each comparison.
- The candidate RPC defaults to `p_limit=500`, earliest first. `process-source.ts` does not pass an explicit limit, so later candidates are omitted silently.
- `process-source.ts:293-311` scans with `rows.find(...)` for each payload. `dedup-utils.ts:42-115` re-canonicalizes titles and allocates two `Set`s on each pairwise comparison.
- Exact-fingerprint matching and the cross-source-only rule are intentional. Exact fingerprints encode the same start minute, so their semantics remain unchanged.
- `_shared/dedup-utils_test.ts` and `scrape-source/lib/process-source_test.ts` are the existing test locations. Match their fixtures and stubs.

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
- `supabase/functions/_shared/dedup-utils.ts`
- `supabase/functions/_shared/dedup-utils_test.ts`
- `supabase/functions/scrape-source/lib/process-source.ts`
- `supabase/functions/scrape-source/lib/process-source_test.ts`

**Out of scope**:
- Candidate RPC SQL or database migrations
- `bulk_import_scrape_events`
- Same-source dedup behavior
- Similarity threshold changes
- Import transaction shape or queue behavior

## Git workflow

- Branch: `advisor/033-dedup-time-window-and-candidate-index`
- Commit per logical unit using Conventional Commits, for example `fix(functions): bound fuzzy dedup by event time`.
- Do NOT push or open a PR unless the operator instructs.

## Steps

### Step 1: Confirm the shared predicate's caller set

Before editing, locate every `isCrossSourceDuplicate` caller under `supabase/functions`. The expected callers are `scrape-source/lib/process-source.ts` and tests only.

**Verify**: `grep -rn "isCrossSourceDuplicate" supabase/functions` → only `process-source.ts`, `dedup-utils.ts`, and their test files are listed. If another production caller exists, follow the STOP condition rather than changing its semantics implicitly.

### Step 2: Enforce ±4 hours in the shared fuzzy predicate

In `dedup-utils.ts`, require a valid, finite time difference no greater than four hours before entering the fuzzy Jaccard branch:

```ts
Math.abs(
  new Date(candidateStart).getTime() - new Date(existingStart).getTime(),
) <= 4 * 60 * 60 * 1000
```

Malformed dates produce `NaN`; treat them as not fuzzy-duplicate and do not throw. Keep the exact-fingerprint arm unchanged. Fix the stale comment so it states that the helper itself enforces the per-pair window.

Add and export:

```ts
export function jaccardFromTokens(
  a: Set<string>,
  b: Set<string>,
): number
```

Reimplement the existing public `jaccardSimilarity(a, b)` as:

```ts
jaccardFromTokens(titleTokens(a), titleTokens(b))
```

Preserve the current empty-set and threshold semantics.

**Verify**: `pnpm run test:functions` → existing dedup utility tests pass with the public signature unchanged.

### Step 3: Raise and expose the candidate cap

In the dedup candidate RPC call in `process-source.ts`, pass `p_limit: 1000` explicitly. When the returned candidate count equals 1000, call:

```ts
logEdgeEvent(
  "warn",
  "cross-source dedup candidate cap reached — duplicates beyond cap may be missed",
  …,
)
```

Include the source identifier and candidate count using existing structured-log conventions. Do not add a fallback query or change the RPC.

**Verify**: the focused `process-source_test.ts` test asserts `p_limit: 1000` is sent and a 1000-row result emits exactly one warning; `pnpm run test:deno` passes.

### Step 4: Pre-index candidate fingerprints, tokens, and hour buckets

Replace the per-payload `rows.find(...)` scan in the dedup pre-pass with one-time candidate preparation. For every candidate, compute and store:

```ts
{ fp, tokens, hourBucket }
```

where `hourBucket = Math.floor(startMs / 3_600_000)`. Build:

```ts
const exactMap = new Map<string, Candidate>();
const bucketMap = new Map<number, Candidate[]>();
```

Canonicalize and tokenize each incoming payload once. Lookup order:

1. Check the exact fingerprint in `exactMap` while preserving the cross-source-only rule.
2. Otherwise inspect only candidates in the nine hour buckets spanning `payloadBucket - 4` through `payloadBucket + 4`.
3. Compare prepared token sets with `jaccardFromTokens`.
4. Keep `candidate.source_id !== source.id` and route the final duplicate decision through the shared predicate so the ±4-hour invariant remains single-sourced.

Avoid copying candidate arrays while scanning buckets. Do not re-canonicalize titles inside the pair loop.

**Verify**: `grep -n "rows.find(" supabase/functions/scrape-source/lib/process-source.ts` → no output; focused tests show recurring events a week apart both import while another-source matches within four hours are skipped.

### Step 5: Add correctness and scale regressions

Extend `dedup-utils_test.ts` with:

- Same fuzzy title at ±3 hours → duplicate.
- Same fuzzy title at ±5 hours → not duplicate.
- Exactly ±4 hours → duplicate.
- Identical fingerprints → duplicate.
- Malformed date strings → not duplicate and no throw.

Extend `process-source_test.ts` with:

- A multi-day batch containing the same recurring title on different weeks → both import.
- A matching title within four hours from another source → skipped.
- More than 500 candidates → a matching candidate beyond the old cap is still deduped.
- Exactly 1000 candidates → warning emitted once.

Use deterministic fixtures and preserve existing source IDs so the cross-source rule is exercised explicitly.

**Verify**: `pnpm run test:functions && pnpm run test:deno` → all utility and process-source regressions pass.

## Test plan

- Utility tests define the inclusive four-hour boundary and malformed-date behavior.
- Process-source tests prove the actual data-loss regression is fixed for weekly recurring titles.
- A >500-row fixture proves the caller no longer relies on the old default cap.
- A 1000-row fixture proves cap saturation is observable without adding an unbounded fallback.
- Existing exact-fingerprint and same-source behavior must remain green.
- Final verification: `pnpm run check`, `pnpm run lint`, `pnpm run test:functions`, and `pnpm run test:deno` all succeed.

## Done criteria

- [ ] Fuzzy duplicates require a valid per-pair start-time difference of at most four hours.
- [ ] Identical fingerprints retain existing behavior.
- [ ] The stale comment no longer claims the RPC bounds each pair.
- [ ] `jaccardFromTokens` is exported and pair loops reuse prepared token sets.
- [ ] The candidate RPC receives `p_limit: 1000` and cap saturation emits one warning.
- [ ] `grep -n "rows.find(" supabase/functions/scrape-source/lib/process-source.ts` returns no matches in the dedup pre-pass.
- [ ] Weekly recurring-title and >500-candidate regressions pass.
- [ ] Relevant Deno/vitest, typecheck, and lint gates pass.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` row 033 is updated.

## STOP conditions

Stop and report back; do not improvise if:

- `isCrossSourceDuplicate` has a production caller other than `process-source.ts`. Make the time check opt-in only if explicitly approved; do not silently alter the new caller.
- The candidate row shape no longer contains the start timestamp, source ID, title fields, or fingerprint inputs needed by the index.
- Preserving semantics requires a candidate RPC or migration change.
- The exact-fingerprint or same-source behavior differs from the documented current state.

## Maintenance notes

- The 1000-row cap is intentionally bounded. If saturation warnings appear in production, profile and plan paginated candidate retrieval separately.
- Keep time-window semantics in `isCrossSourceDuplicate`; an index is an optimization and must not become the only correctness guard.
- Reviewers should look for repeated `titleTokens`/canonicalization inside nested loops and accidental candidate-array allocations.
- The bucket window is a coarse prefilter. The exact millisecond ±4-hour check remains authoritative.
