# Production Setup

Steps required to bring a new Supabase project online for family-events-ui.
Local development is fully handled by `supabase start` + `seed.sql`; this doc
covers what must happen manually in a production environment.

## 1. Push migrations

```bash
supabase link --project-ref <your-project-ref>
supabase db push
```

## 2. Configure scheduled scraping settings

Scheduled scraping uses `pg_cron` + `pg_net` to hit the `scrape-source` edge
function on a cron. Those calls need to know where to reach the function and
how to authenticate. Set once, in Supabase Studio → SQL Editor:

```sql
ALTER DATABASE postgres
  SET app.settings.supabase_url = 'https://<project-ref>.supabase.co';
ALTER DATABASE postgres
  SET app.settings.service_role_key = '<YOUR_SERVICE_ROLE_KEY>';
```

Without these, the cron job silently no-ops (see
`20260415113000_004_schedule_scraping.sql` — it uses `RAISE NOTICE` and
returns early when settings are missing).

## 3. Bootstrap the first admin

There is no admin user in production until you create one.

1. Configure the admin email (once, in SQL Editor):

   ```sql
   ALTER DATABASE postgres SET app.settings.admin_email = 'you@example.com';
   ```

2. Sign up normally in the deployed app at `/sign-up` using that same email.
   This creates the `user_profiles` row with role `user`.

3. Promote to admin:

   ```sql
   SELECT private.bootstrap_admin();
   ```

   Returns `1` if the profile was promoted, `0` if the user hasn't signed up
   yet (in which case repeat step 3 after they do). Idempotent — running it
   after the user is already admin returns `0` and is safe.

For automated verification users, use the idempotent SQL helper in
`supabase/snippets/provision_remote_admin_test_user.sql` after the user signs
up.

## 4. Deploy edge functions

```bash
supabase functions deploy scrape-source
supabase functions deploy tag-event
supabase functions deploy process-tag-queue
supabase functions deploy share-og
supabase functions deploy notify-email
```

Verify AI provider secrets are set in Supabase if you want model-backed tagging.
OpenAI is the default via OPENAI_API_KEY and OPENAI_MODEL. For a self-hosted
OpenAI-compatible provider such as Ollama/Qwen3 on Railway, see
[`LOCAL_LLM_TAGGING.md`](./LOCAL_LLM_TAGGING.md). Without a configured provider,
tag-event falls back to keyword matching (check `events.ai_tag_provider` to
audit which path is running).

## 5. Configure email (Resend)

Application emails (admin notification on new invite request, code delivery
on approval) and Supabase Auth emails (signup confirmation, password reset)
both route through Resend. One Resend account + API key serves both paths.

See [`supabase/docs/EMAIL.md`](./EMAIL.md) for the full setup walkthrough:
domain verification, Supabase × Resend integration for Auth, secrets for
`notify-email`, and verification queries.

Without configured email, the invite-request feature still works
end-to-end at the data layer — admins just have to copy codes manually
from `/admin/invites` and share them out of band.

## 6. Verify

- `/sign-in` with the admin credentials
- Navigate to `/admin` — should load without redirecting
- Trigger a scrape from `/admin/sources` — `source_runs` row should show `status=success`
- Check `events` table for new rows with `status=draft` and populated `ai_tag_provider`
