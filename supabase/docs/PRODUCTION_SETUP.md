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

## 4. Deploy edge functions

```bash
supabase functions deploy scrape-source
supabase functions deploy tag-event
```

Verify OPENAI_API_KEY and OPENAI_MODEL are set in Supabase project secrets if
you want AI tagging. Without them, tag-event falls back to keyword matching
(check `events.ai_tag_provider` to audit which path is running).

## 5. Verify

- `/sign-in` with the admin credentials
- Navigate to `/admin` — should load without redirecting
- Trigger a scrape from `/admin/sources` — `source_runs` row should show `status=success`
- Check `events` table for new rows with `status=draft` and populated `ai_tag_provider`
