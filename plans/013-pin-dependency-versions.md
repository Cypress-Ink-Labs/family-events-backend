# Plan 013: Dependency versions are pinned consistently across the workspace

> **Executor instructions**: Follow step by step. Honor STOP conditions. Update this plan's row in
> `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 6c0db23..HEAD -- packages/email/package.json packages/deploy-cli/package.json package.json supabase/functions`

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW (version-constraint alignment; verified by typecheck + install)
- **Depends on**: none
- **Category**: deps
- **Planned at**: commit `6c0db23`, 2026-06-17

## Why this matters

Three small version-hygiene issues reduce reproducibility:

1. `packages/email/package.json` pins `@types/node`, `@types/react`, `@types/react-dom`, and `tsx` to
   **`latest`** — every reinstall can silently pull a new major and break typecheck non-deterministically.
2. `packages/deploy-cli/package.json` uses `oxfmt@^0.54.0` and `vitest@4.1.8` while root uses
   `oxfmt@^0.55.0` and `vitest@4.1.9` — divergent tool versions across the monorepo.
3. All 22 `supabase/functions/*/deno.json` pin `@supabase/supabase-js@^2.108.1` while the root workspace
   uses `^2.108.2` — a cosmetic but real inconsistency in the single most critical dependency.

None is a vulnerability; together they're the difference between reproducible and "works on my machine."

## Current state

- `packages/email/package.json:24-27`:
  ```json
  "@types/node": "latest",
  "@types/react": "latest",
  "@types/react-dom": "latest",
  "tsx": "latest"
  ```
- `packages/deploy-cli/package.json:28,31`: `"oxfmt": "^0.54.0"`, `"vitest": "4.1.8"`.
- Root `package.json:36,39,41`: `"oxfmt": "^0.55.0"`, `"tsx": "^4.22.4"`, `"vitest": "4.1.9"`.
- `supabase/functions/*/deno.json` imports: `"@supabase/supabase-js": "npm:@supabase/supabase-js@^2.108.1"`
  (22 files, all identical); root devDep is `^2.108.2`.

## Steps

### Step 1: Pin email package types + tsx

Replace the four `latest` constraints in `packages/email/package.json` with concrete ranges matching the
workspace: `@types/node` → `^25.9.3` (root), `tsx` → `^4.22.4` (root). For `@types/react` /
`@types/react-dom`, pin to the currently-resolved versions (read them from `pnpm-lock.yaml` after a dry
resolve, or `pnpm why @types/react`) using a caret range, e.g. `^19.x.y` to match `react@^19.2.7`.

### Step 2: Align deploy-cli tool versions

In `packages/deploy-cli/package.json` set `oxfmt` → `^0.55.0` and `vitest` → `4.1.9` to match root.

### Step 3: Align deno.json supabase-js pin

Bump all `supabase/functions/*/deno.json` `@supabase/supabase-js` imports from `^2.108.1` to `^2.108.2`
(match root). This is a mechanical find/replace across the 22 files; confirm the count:
`grep -rl 'supabase-js@\^2.108.1' supabase/functions | wc -l` before and after (after → 0).

### Step 4: Reinstall + verify

`pnpm install` (updates `pnpm-lock.yaml`), then `pnpm run check`. The lockfile change should be reviewed.

## Commands you will need

| Purpose                   | Command                                                    | Expected                      |
| ------------------------- | ---------------------------------------------------------- | ----------------------------- |
| Resolve react types       | `pnpm why @types/react`                                    | shows resolved version to pin |
| Install                   | `pnpm install`                                             | exit 0; lockfile updates      |
| Typecheck                 | `pnpm run check`                                           | exit 0                        |
| Confirm deno pins         | `grep -rl 'supabase-js@\^2.108.1' supabase/functions`      | no matches                    |
| Deno typecheck (optional) | `deno check` in `supabase/functions` (or `pnpm run check`) | no new errors                 |

## Done criteria

- [ ] No `"latest"` constraints remain in `packages/email/package.json`
- [ ] `packages/deploy-cli/package.json` oxfmt/vitest match root
- [ ] All `deno.json` use `@supabase/supabase-js@^2.108.2`
- [ ] `pnpm install` succeeds; `pnpm run check` exits 0
- [ ] `pnpm-lock.yaml` changes reviewed and committed
- [ ] `plans/README.md` row for 013 updated

## STOP conditions

- Pinning `@types/react`/`@types/react-dom` to the resolved version introduces a typecheck error in
  `packages/email` — report the error; do not revert to `latest` (find the compatible pin instead).
- Bumping deno supabase-js to `^2.108.2` surfaces a Deno type/check error — report; the pin is cosmetic
  (the caret already allows 2.108.2), so a failure indicates a real incompatibility worth surfacing.

## Maintenance notes

- The working tree already has `pnpm-lock.yaml` modified (per `git status` at plan time) for unrelated
  reasons — keep your lockfile change scoped to these dependency edits; if the diff is noisy, note it.
- Reviewer: confirm no `latest` anywhere (`grep -rn '"latest"' packages/*/package.json`).
