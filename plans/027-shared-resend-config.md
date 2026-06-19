# Plan 027: Extract a shared Resend config module

> **Executor instructions**: Follow step by step; run every verification command.
> STOP conditions halt you. Update `plans/README.md` when done.
>
> **Drift check (run first)**:
> `grep -rn "RESEND_API_ENDPOINT\s*=\|RESEND_TIMEOUT_MS\s*=" supabase/functions --include='index.ts'`
> Expect the 5 declarations listed below; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: tech-debt
- **Planned at**: commit `5daa274`, 2026-06-19

## Why this matters

`RESEND_API_ENDPOINT` and `RESEND_TIMEOUT_MS` are copy-pasted identically across
five functions. A change to the endpoint or timeout policy means editing five
files in lockstep, with drift risk. One shared module is the single source of truth.

## Current state (verified)

Identical declarations in:
- `supabase/functions/notify-email/index.ts:23-24`
- `supabase/functions/send-reminders/index.ts:24-25`
- `supabase/functions/send-weekly-digest/index.ts:15-16`
- `supabase/functions/send-auth-email/index.ts:26-27`
- `supabase/functions/process-notification-queue/index.ts:15-16`

Each is:
```ts
const RESEND_API_ENDPOINT = "https://api.resend.com/emails"
const RESEND_TIMEOUT_MS = 10_000
```

Shared modules live in `supabase/functions/_shared/` and are imported with `.ts`
extensions per the import map (`supabase/functions/deno.json`). See any existing
`_shared` import in these functions for the exact relative path style (`../_shared/...`).

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Typecheck | `pnpm run check` | exit 0 |
| Lint | `pnpm run lint` | exit 0 |
| Format check | `pnpm run format:check` | exit 0 |
| Deno tests | `pnpm run test:deno` | all pass |
| knip | `pnpm run knip` | no new hints |

## Scope

**In scope**:
- `supabase/functions/_shared/resend-config.ts` (create) — export `RESEND_API_ENDPOINT` and `RESEND_TIMEOUT_MS`.
- The five `index.ts` files above — remove the local consts, import from `_shared/resend-config.ts`.

**Out of scope**: any change to how Resend is called (headers, body, retry), the
`RESEND_API_KEY`/`RESEND_FROM` env reads (those stay per-function), and any other constant.

## Git workflow

- Branch: `advisor/027-shared-resend-config`
- Conventional Commits, e.g. `refactor(functions): extract shared Resend config`.
- Do NOT push or open a PR unless instructed.

## Steps

### Step 1: Create the shared module
`supabase/functions/_shared/resend-config.ts`:
```ts
export const RESEND_API_ENDPOINT = "https://api.resend.com/emails"
export const RESEND_TIMEOUT_MS = 10_000
```

### Step 2: Replace in all five functions
Remove each local `const RESEND_API_ENDPOINT`/`RESEND_TIMEOUT_MS` and add
`import { RESEND_API_ENDPOINT, RESEND_TIMEOUT_MS } from "../_shared/resend-config.ts"`
(match the relative depth + `.ts` extension used by that file's other `_shared` imports).
**Verify**: `grep -rn "const RESEND_API_ENDPOINT\|const RESEND_TIMEOUT_MS" supabase/functions --include='index.ts'` → no matches.

### Step 3: full gates
**Verify**: `pnpm run check` → 0; `pnpm run lint` → 0; `pnpm run format:check` → 0; `pnpm run test:deno` → pass; `pnpm run knip` → no new hints.

## Test plan

- No behavior change; existing tests stay green. No new test required (constants).
- Verification: `pnpm run test:deno` passes; `pnpm run knip` shows the new export is used (no unused-export hint).

## Done criteria

- [ ] `_shared/resend-config.ts` exports both constants
- [ ] All five functions import them; zero local re-declarations remain (grep clean)
- [ ] `pnpm run check`/`lint`/`format:check` → 0; `test:deno` pass; `knip` no new hints
- [ ] `plans/README.md` status row updated

## STOP conditions

- A function declares a DIFFERENT endpoint/timeout value than the shared one (drift) — STOP and report (don't silently change behavior).
- The `_shared` import path can't be resolved by the import map — STOP.

## Maintenance notes

- New email-sending functions should import from `_shared/resend-config.ts`.
- Reviewer: confirm the import path/extension matches the repo's `_shared` convention and no value changed.
