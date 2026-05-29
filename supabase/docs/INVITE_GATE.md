# Invite Gate

Controls whether new sign-ups require a valid invite code. When enabled,
users must present an invite code during registration. When disabled
(the default), anyone can sign up freely.

The setting lives in the Postgres GUC `app.settings.require_invite`. All
invite-related functions read this value at runtime via
`current_setting('app.settings.require_invite', true)` and **default to
`'false'`** (open registration) when the setting is absent.

## Affected Functions

| Function | Role | How it uses the GUC |
|----------|------|---------------------|
| `private.invites_required()` | Helper | Returns `true` when the GUC is `'true'`. Defaults to `false` when unset. Single source of truth for gate status. |
| `public.invites_required()` | Public wrapper | Thin invoker wrapper — calls `private.invites_required()`. Safe to call from the client. |
| `private.enforce_invited_oauth_signup()` | Trigger (`BEFORE INSERT` on `auth.users`) | Blocks OAuth sign-ups (Google/Apple) when gating is enabled, unless a `pending_invite_claims` row exists for the email. |
| `public.handle_new_user()` | Trigger (`AFTER INSERT` on `auth.users`) | Creates the `user_profiles` row. When gating is enabled, checks for a matching `invite_codes` redemption and sets the profile accordingly. |

## Current State

The gate is **disabled** by default. The `invites_required()` function
returns `false` when the GUC is absent, which is the normal state on both
local dev and Supabase Cloud.

## Re-enable Gate (Closed Beta)

Run in **Supabase Dashboard → SQL Editor**:

```sql
-- Option A: ALTER ROLE (persists across connections)
ALTER ROLE postgres SET app.settings.require_invite = 'true';

-- Option B: Session-level (current connection only)
SELECT set_config('app.settings.require_invite', 'true', false);
```

> **Note:** `ALTER ROLE` is supported on Supabase Cloud (unlike `ALTER
> DATABASE` which is blocked for custom GUCs). New connections will inherit
> the updated value. Existing pooled connections keep the old value until
> they reconnect.

## Disable Gate (Open Registration)

If the gate was previously enabled, remove the override:

```sql
-- Remove the ROLE-level override so it falls back to default (false)
ALTER ROLE postgres RESET app.settings.require_invite;
```

Or set it explicitly:

```sql
ALTER ROLE postgres SET app.settings.require_invite = 'false';
```

## Verification

After toggling, verify the change took effect (open a **new** SQL Editor
tab to get a fresh connection):

```sql
SELECT public.invites_required();
```

| Gate state | Result |
|------------|--------|
| Enabled    | `true` |
| Disabled   | `false` |

## Local Development

The migration `20260601012000_disable_invite_gate.sql` changed the
`invites_required()` function to default to `false`, so local dev starts
with open registration out of the box.

To temporarily re-enable the gate in a local session (useful for testing
invite flows):

```sql
SELECT set_config('app.settings.require_invite', 'true', false);
```

To revert within the same session:

```sql
SELECT set_config('app.settings.require_invite', 'false', false);
```

## See Also

- [`PRODUCTION_SETUP.md`](./PRODUCTION_SETUP.md) — other `app.settings.*`
  configuration (Supabase URL, service role key, admin email)
