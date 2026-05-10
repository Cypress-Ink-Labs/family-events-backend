-- Remote admin test-user provisioning helper
-- Purpose:
--   Promote an existing signed-up test user to admin in remote environments
--   without committing credentials into migrations or seed files.
--
-- Usage:
--   1) Replace <TEST_ADMIN_EMAIL> with the real test admin email.
--   2) Run in Supabase SQL editor after that user has signed up once.
--   3) Re-running is safe and idempotent.

-- Idempotent promotion:
UPDATE public.user_profiles
SET role = 'admin'
WHERE lower(email) = lower('lecoqjacob@gmail.com')
  AND role <> 'admin';

-- Verify effective role:
SELECT id, email, role
FROM public.user_profiles
WHERE lower(email) = lower('lecoqjacob@gmail.com');

-- Optional rollback:
-- UPDATE public.user_profiles
-- SET role = 'user'
-- WHERE lower(email) = lower('<TEST_ADMIN_EMAIL>')
--   AND role = 'admin';
