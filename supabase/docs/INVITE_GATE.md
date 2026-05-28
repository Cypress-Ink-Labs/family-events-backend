# Invite Gate

Controls whether new sign-ups require a valid invite code. When enabled (the
default in production), users must present an invite code during registration.
When disabled, anyone can sign up freely.

The setting lives in the Postgres GUC `app.settings.require_invite`. All
invite-related functions read this value at runtime via
`current_setting('app.settings.require_invite', true)` and default to `'true'`
when the setting is absent.

## Affected Functions

| Function | Role | How it uses the GUC |
|----------|------|---------------------|
| `private.invites_required()` | Helper | Returns `true` when the GUC is `'true'` or unset. Single source of truth for gate status. |
| `public.invites_required()` | Public wrapper | Thin invoker wrapper — calls `private.invites_required()`. Safe to call from the client. |
| `private.enforce_invited_oauth_signup()` | Trigger (`BEFORE INSERT` on `auth.users`) | Blocks OAuth sign-ups (Google/Apple) when gating is enabled, unless a `pending_invite_claims` row exists for the email. |
| `public.handle_new_user()` | Trigger (`AFTER INSERT` on `auth.users`) | Creates the `user_profiles` row. When gating is enabled, checks for a matching `invite_codes` redemption and sets the profile accordingly. |

## Disable Gate (Open Registration)

Run in **Supabase Dashboard → SQL Editor**:

```sql
ALTER DATABASE postgres SET app.settings.require_invite = 'false';
```

New database connections will inherit the updated default. Existing
connections (pooled or long-lived) continue using the old value until they
reconnect.

## Re-enable Gate (Closed Beta)

Run in **Supabase Dashboard → SQL Editor**:

```sql
ALTER DATABASE postgres SET app.settings.require_invite = 'true';
```

Same reconnection caveat applies — existing sessions keep the prior value.

## Verification

After toggling, verify the change took effect:

```sql
SELECT public.invites_required();
```

Expected return value:

| Gate state | Result |
|------------|--------|
| Enabled    | `true` |
| Disabled   | `false` |

> **Note:** If the query still returns the old value, you are on a session
> that was established before the `ALTER DATABASE`. Open a new SQL Editor tab
> (which creates a fresh connection) and re-run the query.

## Local Development

The migration `20260601012000_disable_invite_gate.sql` sets the GUC to
`'false'` at the database level so local dev starts with open registration
out of the box.

To temporarily re-enable the gate in a local session (useful for testing
invite flows):

```sql
SELECT set_config('app.settings.require_invite', 'true', false);
```

The `false` argument means the override lasts for the entire session, not
just the current transaction. This does not affect other connections.

To revert within the same session:

```sql
SELECT set_config('app.settings.require_invite', 'false', false);
```

## See Also

- [`PRODUCTION_SETUP.md`](./PRODUCTION_SETUP.md) — other `app.settings.*`
  configuration (Supabase URL, service role key, admin email)
