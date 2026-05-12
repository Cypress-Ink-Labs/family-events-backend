# Email Setup

Two distinct email pipelines run side-by-side. Understanding which one
handles what is the operator's most important mental model when something
isn't being delivered.

## What sends what

| Email kind                                    | Triggered by                       | Sent by                             |
| --------------------------------------------- | ---------------------------------- | ----------------------------------- |
| Signup confirmation                           | `supabase.auth.signUp()`           | **Supabase Auth** (via Resend SMTP) |
| Password reset                                | `supabase.auth.resetPasswordFor…`  | **Supabase Auth** (via Resend SMTP) |
| Magic link / OTP                              | `supabase.auth.signInWithOtp()`    | **Supabase Auth** (via Resend SMTP) |
| Email change confirmation                     | `supabase.auth.updateUser({email})`| **Supabase Auth** (via Resend SMTP) |
| Admin notification: "new invite request"      | `public.request_invite(...)` RPC   | **`notify-email` edge function**    |
| Requester notification: "your code is XYZ"    | `admin_approve_invite_request` RPC | **`notify-email` edge function**    |

The first four are **Auth-flow emails** — built into Supabase Auth, with
templates editable in the dashboard. The bottom two are **application
transactional emails** — built in this repo, triggered by our own RPCs via
`pg_net.http_post` → `notify-email` → Resend REST API.

One Resend account + one API key + one verified domain serves both paths.
Auth consumes the key via SMTP; `notify-email` consumes the same key via
REST.

## One-time setup

### 1. Resend account + verified domain

1. Sign up at [resend.com](https://resend.com) — free tier covers 3,000
   emails/month and 100/day.
2. Add and verify your sending domain (DKIM + SPF DNS records). Until the
   domain verifies, sends will fall back to `onboarding@resend.dev` which
   is rate-limited and brands the email "via resend.dev".
3. Create an API key in the Resend dashboard → API Keys. The same key works
   for both SMTP and REST.

### 2. Wire Supabase Auth → Resend (Auth-flow emails)

Two options. The official integration is faster; manual SMTP is easier to
audit.

**Option A — Supabase Resend integration (recommended):**

1. In the Supabase dashboard, navigate to your project →
   [Integrations](https://supabase.com/partners/integrations/resend) → Resend.
2. Click **Install** and authorize the OAuth-style flow.
3. Select the verified domain to use as the sender. Save.

Supabase writes the SMTP config into `auth.email.smtp` for you.

**Option B — Manual SMTP config:**

1. Dashboard → Authentication → Emails → SMTP Settings → Enable.
2. Host: `smtp.resend.com`, Port: `465`, User: `resend`, Password: your
   Resend API key.
3. Sender email + sender name: as you want it to appear to users. Save.

Either way, Supabase will start routing Auth emails through Resend
immediately. Trigger a password-reset on a test account to verify.

### 3. Wire `notify-email` (application emails)

```bash
# Deploy the function
supabase functions deploy notify-email --linked

# Set the four secrets
supabase secrets set --linked \
  RESEND_API_KEY=re_xxxxxxxxxxxxxxxx \
  RESEND_FROM='Family Events <notifications@yourdomain.com>' \
  ADMIN_NOTIFY_EMAIL=you@yourdomain.com \
  APP_URL=https://family-events.up.railway.app
```

`RESEND_FROM` must be on the verified domain from step 1. `APP_URL` is the
public root URL of your Railway frontend — used to build the "Review in
admin" and "Create your account" CTA links.

### 4. Apply the wiring migration

```bash
supabase db push --linked
```

This applies `20260601001600_invite_email_notifications.sql`, which wires
`request_invite` + `admin_approve_invite_request` to fire-and-forget POST to
`notify-email` via `pg_net.http_post`. The migration reuses the same
`vault.secrets`/GUC fallback pattern as `invoke_scrape_source`, so no
additional secrets are needed for the DB → function hop.

## Soft-failure behaviour

`notify-email` is designed to never break the user-facing flow if email is
misconfigured. The cascade:

| Missing             | Function returns                            | User impact |
| ------------------- | ------------------------------------------- | ----------- |
| `RESEND_API_KEY`    | `200 {sent:false, dev:true}` (logs payload) | None        |
| `ADMIN_NOTIFY_EMAIL`| `200 {sent:false, reason:"no_admin_email"}` | None        |
| Resend returns 5xx  | `502 {sent:false, error:"resend_5xx"}`      | None        |

The RPCs `request_invite` and `admin_approve_invite_request` always succeed
as long as the DB write succeeds. The async `pg_net` call to `notify-email`
runs in the background and any failure is captured to Sentry; the user-
facing return value is unaffected.

## Verifying email delivery

`pg_net` writes every outbound HTTP call to `net._http_response`. This is
the diagnostic source of truth for application emails.

```sql
SELECT id, status_code, content_type, substring(content::text, 1, 200) AS body
FROM net._http_response
WHERE created > now() - interval '5 minutes'
ORDER BY created DESC;
```

What to look for:

- `status_code=200`, body `{"sent":true,"id":"re_..."}` → email sent. Verify
  in Resend dashboard → Logs.
- `{"sent":false,"dev":true}` → `RESEND_API_KEY` is unset on the function.
- `{"sent":false,"reason":"no_admin_email"}` → `ADMIN_NOTIFY_EMAIL` unset.
- `status_code` ≥ 400 → Resend or the function rejected the call. Check
  Sentry breadcrumbs or `supabase functions logs notify-email --linked`.

For Auth emails, check Supabase dashboard → Authentication → Logs. The
"Sent" / "Failed" markers show provider response codes from Resend SMTP.

## Customizing email content

- **Auth emails:** Supabase dashboard → Authentication → Emails →
  Templates. Each template (Confirm signup, Reset password, etc.) has HTML
  + plain-text fields with `{{ .ConfirmationURL }}`-style mustache
  variables.
- **Application emails:** edit `renderAdminRequest` and
  `renderRequestApproved` in
  `supabase/functions/notify-email/index.ts`. Plain inline HTML strings —
  no React Email dependency. Redeploy with
  `supabase functions deploy notify-email --linked`.

## Cost notes

Resend free tier is 3k/month / 100/day, which comfortably covers a closed
beta. Past that, $20/month for 50k. If application emails ever exceed Auth
volume by an order of magnitude, consider splitting them onto a separate
Resend project so deliverability reputation stays isolated.
