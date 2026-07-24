# Plan 030: Fix cron-runner HTTP status classification

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving on. Honor STOP conditions — do not improvise. When done, update your row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 2f10101..HEAD -- cron/_shared/cron-runner.sh cron/*/cron-runner.sh scripts/sync-cron-runner.sh tests/guards/cron-runner-boundary.test.mjs tests/guards/cron-runner-http-classification.test.mjs package.json`
> If any in-scope file changed since this plan was written, compare the "Current state" excerpts against the live code before proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `2f10101`, 2026-07-24

## Why this matters

`cron/_shared/cron-runner.sh` appends a fallback string to curl's `%{http_code}` output. If curl prints `200` and then fails while reading the response body, the script receives `2000`, converts it to integer 2000, and matches the existing `2*` success case. A failed cron invocation is therefore logged and reported as successful. The same defect can make a failed `log-cron-run` POST appear successful. All eight Railway cron services run synchronized copies of this script.

## Current state

- `cron/_shared/cron-runner.sh:166-177` performs the target call:
  ```sh
  HTTP_RAW=$(curl --silent --show-error --max-time 170 \
    -o "$BODY_FILE" -w "%{http_code}" \
    -X POST … "$URL" -d "$(printf '{"cron_run_key":"%s","cron_label":"%s"}' "$RUN_KEY" "$LABEL")" 2>/dev/null || echo "0")
  HTTP=$(printf '%d' "${HTTP_RAW:-0}" 2>/dev/null || echo 0)
  ```
- `cron/_shared/cron-runner.sh:181-193` classifies `5*|0` for retry, `2*` for success, and everything else for failure.
- `log_run` at approximately lines 76-90 uses the same concatenation pattern with `|| echo "000"`; its `case "$log_http" in 2*)` branch reports success.
- `is_enabled` at approximately lines 101-116 also uses the pattern. Its body validation happens to fail closed today, but the status capture is still incorrect.
- `scripts/sync-cron-runner.sh` is the canonical propagation mechanism. `tests/guards/cron-runner-boundary.test.mjs` verifies that the eight cron-directory copies match `cron/_shared/cron-runner.sh`. Match those conventions rather than editing copies independently.

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
- `cron/_shared/cron-runner.sh`
- The eight generated `cron/*/cron-runner.sh` copies listed by `scripts/sync-cron-runner.sh`
- `tests/guards/cron-runner-http-classification.test.mjs` (new)
- `package.json` (workspace-test registration only)

**Read-only helper**:
- `scripts/sync-cron-runner.sh` — run it; change it only if its existing output list has drifted and that does not trigger a STOP condition.
- `tests/guards/cron-runner-boundary.test.mjs` — structural test exemplar.

**Out of scope**:
- Retry policy, retry labels, or existing `case` behavior
- Supabase Edge Functions
- Deploy CLI behavior
- Any cron scheduling or Railway configuration

## Git workflow

- Branch: `advisor/030-fix-cron-runner-http-classification`
- Commit per logical unit using Conventional Commits, for example `fix(cron): classify curl failures correctly`.
- Do NOT push or open a PR unless the operator instructs.

## Steps

### Step 1: Separate curl exit status from HTTP status

In all three curl sites in `cron/_shared/cron-runner.sh`, remove the `|| echo "0"` or `|| echo "000"` suffix and capture curl's exit code immediately after command substitution. Use the site's existing variable names:

```sh
HTTP_RAW=$(curl … 2>/dev/null)
CURL_EXIT=$?
if [ "$CURL_EXIT" -ne 0 ]; then
  HTTP=0
else
  HTTP=$(printf '%d' "${HTTP_RAW:-0}" 2>/dev/null || echo 0)
fi
```

Use corresponding local names for `log_run` (`log_http`) and `is_enabled` (`enabled_http`) so nested function calls cannot overwrite state. Preserve the current `case` arms and retry policy byte-for-byte.

**Verify**: `grep -n '|| echo "0' cron/_shared/cron-runner.sh` → no output; `sh -n cron/_shared/cron-runner.sh` → exit 0.

### Step 2: Synchronize all cron copies

Run `bash scripts/sync-cron-runner.sh` once. Do not hand-edit the generated copies.

**Verify**: `node --test tests/guards/cron-runner-boundary.test.mjs` → all tests pass and all eight copies are identical to the canonical script.

### Step 3: Add a behavioral guard for post-header curl failures

Create `tests/guards/cron-runner-http-classification.test.mjs` with `node:test`, following the temp-directory and process-spawn conventions in `cron-runner-boundary.test.mjs`.

Build a temporary `curl` stub, prepend its directory to `PATH`, and run:

```sh
sh cron/_shared/cron-runner.sh "$TARGET_URL" cron-test
```

The stub must branch on the URL argument:

- `$IS_CRON_ENABLED_URL`: write `true` to the file supplied by `-o`, print `200`, exit 0.
- Target URL: print `200`, then exit 28.
- `$LOG_CRON_RUN_URL`: print `200`, exit 0.

Set `IS_CRON_ENABLED_URL`, `LOG_CRON_RUN_URL`, and `SUPABASE_SERVICE_ROLE_KEY=x`. Assert that the runner exits nonzero, stdout contains `"msg":"curl failed (network/timeout)"`, and stdout does not contain `"status":"succeeded"`. Add a success case where the target stub prints `200` and exits 0; the runner must exit 0. Register the new file in the `workspace:test` script in `package.json`.

**Verify**: `pnpm run workspace:test` → all guard tests pass, including both new cases.

### Step 4: Prove the new guard detects the old defect

Temporarily restore the old target-call `|| echo "0"` behavior without committing it, run only the new guard, confirm it fails, then restore the fixed implementation.

**Verify**: the temporary mutation makes `node --test tests/guards/cron-runner-http-classification.test.mjs` fail; after restoring the fix, the same command passes.

## Test plan

- Model the new Node test after `tests/guards/cron-runner-boundary.test.mjs`.
- Cover a target request that prints HTTP 200 but exits 28; it must be a failure and never emit a succeeded status.
- Cover a normal target request that prints HTTP 200 and exits 0; it must remain successful.
- Keep kill-switch and log endpoint stubs deterministic and network-free.
- Perform the mutation check so the test proves the exact regression rather than merely exercising the script.
- Final verification: `pnpm run workspace:test` → all pass.

## Done criteria

- [ ] `pnpm run workspace:test` passes with the new behavioral guard.
- [ ] `grep -n '|| echo "0' cron/_shared/cron-runner.sh` returns no matches.
- [ ] All eight cron-directory copies are identical to `cron/_shared/cron-runner.sh`.
- [ ] A post-header curl failure returns nonzero and is not logged as succeeded.
- [ ] A normal HTTP 200 with curl exit 0 still succeeds.
- [ ] The mutation check was performed and failed against the old behavior.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` row 030 is updated.

## STOP conditions

Stop and report back; do not improvise if:

- The live script no longer matches the excerpts or the existing classification arms changed.
- A cron directory not listed in `scripts/sync-cron-runner.sh` contains another runner copy.
- The stub-curl approach cannot work on the CI shell. In that case, fall back only to a string-structure assertion in the existing boundary test and report the limitation.
- The change appears to require altering retry policy or deploy behavior.

## Maintenance notes

- `cron/_shared/cron-runner.sh` remains canonical; future changes must be propagated with `scripts/sync-cron-runner.sh`.
- Reviewers should confirm exit status is captured immediately after each curl invocation and before any other command can overwrite `$?`.
- Keep the behavioral guard focused on status/exit separation. Retry tuning and kill-switch observability are separate findings.
