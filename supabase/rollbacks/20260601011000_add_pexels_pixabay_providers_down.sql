-- Rollback for 20260601011000_add_pexels_pixabay_providers.sql
--
-- 011000 UP (supabase/migrations/20260601011000_add_pexels_pixabay_providers.sql)
-- did, on public.event_image_attributions:
--   1. DROP CONSTRAINT event_image_attributions_provider_check         (UP lines 15-16)
--   2. ADD  CONSTRAINT event_image_attributions_provider_check
--           CHECK (provider IN ('pexels','pixabay','unsplash'))         (UP lines 19-21)
--   3. ALTER COLUMN ... DROP NOT NULL on 6 unsplash_* columns           (UP lines 24-30)
--   4. ADD COLUMN IF NOT EXISTS pexels_* (4 cols)                       (UP lines 33-37)
--   5. ADD COLUMN IF NOT EXISTS pixabay_* (4 cols)                      (UP lines 40-44)
--   6. ADD CONSTRAINT event_image_attributions_provider_fields_check    (UP lines 47-68)
--   7. COMMENT ON TABLE / COMMENT ON COLUMN provider                    (UP lines 71-75)
--
-- This file reverses 011000 fully back to the pre-011000 (== 006000) state.
--
-- ROLLBACK ORDERING (rollbacks run NEWEST-first):
--   20260601011001_fix_provider_constraint_down.sql runs BEFORE this file and
--   already drops both CHECK constraints. This file therefore uses
--   DROP CONSTRAINT IF EXISTS so it is a safe no-op if 011001_down ran first,
--   and still correct if this file is ever run standalone.
--
-- PRIOR DEFINITIONS / SOURCES (pre-011000 state of the table):
--   Table created in supabase/migrations/20260601006000_enrichment_images_and_rpc_cleanup.sql:974-994
--     - provider column + inline CHECK:
--         provider text NOT NULL DEFAULT 'unsplash' CHECK (provider = 'unsplash')   (006000:978)
--       A single-column inline CHECK is auto-named "<table>_<column>_check", i.e.
--       event_image_attributions_provider_check — the exact name 011000 dropped.
--       Prior constraint body restored below = CHECK (provider = 'unsplash').
--     - The 6 unsplash_* columns were all declared NOT NULL:
--         unsplash_photo_id, unsplash_photographer_name,
--         unsplash_photographer_username, unsplash_photographer_profile_url,
--         unsplash_photo_url, unsplash_download_location                            (006000:980-985)
--   Intervening migrations 007000-010000 do NOT touch this table's columns or
--   provider constraint (verified), so 006000 is the definitive prior state.
--
--   pexels_*/pixabay_* columns: NOT present in 006000/baseline. They were first
--   introduced by 011000 (UP lines 33-44). Therefore dropping them here restores
--   the prior schema and does NOT corrupt baseline state (see STOP note 2).
--
-- =============================== STOP / IRREVERSIBILITY ======================
-- STOP 1 (DATA-CONDITIONAL — restoring NOT NULL on unsplash_* columns):
--   011000 made the 6 unsplash_* columns nullable so that provider='pexels' and
--   provider='pixabay' rows could leave them NULL. If ANY pexels/pixabay rows
--   exist (or any unsplash row was written with a NULL unsplash_* value), the
--   ALTER COLUMN ... SET NOT NULL statements below WILL FAIL. This is expected:
--   you cannot return to the unsplash-only schema while non-unsplash data lives
--   in the table. Before running this rollback you must first delete or migrate
--   such rows, e.g.:
--       DELETE FROM public.event_image_attributions WHERE provider <> 'unsplash';
--   (run that manually and deliberately — this file does NOT delete data).
--
-- STOP 2 (DROP COLUMN — data loss for non-unsplash attributions):
--   Dropping the pexels_*/pixabay_* columns destroys any data stored in them.
--   Because STOP 1 already requires removing non-unsplash rows first, these
--   columns should be empty at that point; the DROP COLUMN then loses nothing.
--   The columns are unconditionally dropped (NOT IF-EXISTS-guarded against
--   baseline) because they do not exist in baseline/006000 — 011000 created
--   them, so this drop is the correct inverse and cannot corrupt baseline state.
-- ============================================================================

BEGIN;

-- Reverse step 6 / step 2: drop the constraints 011000 added.
-- (011001_down likely already dropped these; IF EXISTS makes this idempotent.)
ALTER TABLE public.event_image_attributions
  DROP CONSTRAINT IF EXISTS event_image_attributions_provider_fields_check;

ALTER TABLE public.event_image_attributions
  DROP CONSTRAINT IF EXISTS event_image_attributions_provider_check;

-- Reverse steps 4 & 5: drop the pexels_* and pixabay_* columns.
-- These did not exist before 011000 (see PRIOR DEFINITIONS / STOP 2).
ALTER TABLE public.event_image_attributions
  DROP COLUMN IF EXISTS pexels_photo_id,
  DROP COLUMN IF EXISTS pexels_photographer_name,
  DROP COLUMN IF EXISTS pexels_photographer_profile_url,
  DROP COLUMN IF EXISTS pexels_photo_url,
  DROP COLUMN IF EXISTS pixabay_photo_id,
  DROP COLUMN IF EXISTS pixabay_photographer_name,
  DROP COLUMN IF EXISTS pixabay_photographer_username,
  DROP COLUMN IF EXISTS pixabay_photo_url;

-- Reverse step 1 / restore prior constraint: re-add the original single-provider
-- CHECK exactly as defined inline in 006000:978.
ALTER TABLE public.event_image_attributions
  ADD CONSTRAINT event_image_attributions_provider_check
  CHECK (provider = 'unsplash');

-- Reverse step 3: restore NOT NULL on the 6 unsplash_* columns (006000:980-985).
-- DATA-CONDITIONAL — see STOP 1. Fails if any column holds a NULL (i.e. if any
-- non-unsplash rows remain). Remove/migrate those rows first.
ALTER TABLE public.event_image_attributions
  ALTER COLUMN unsplash_photo_id SET NOT NULL,
  ALTER COLUMN unsplash_photographer_name SET NOT NULL,
  ALTER COLUMN unsplash_photographer_username SET NOT NULL,
  ALTER COLUMN unsplash_photographer_profile_url SET NOT NULL,
  ALTER COLUMN unsplash_photo_url SET NOT NULL,
  ALTER COLUMN unsplash_download_location SET NOT NULL;

-- Reverse step 7: restore the COMMENTs to their pre-011000 state.
-- 006000 set no COMMENT on the table or the provider column, so the prior state
-- is "no comment". Resetting to NULL returns to that state.
COMMENT ON TABLE public.event_image_attributions IS NULL;
COMMENT ON COLUMN public.event_image_attributions.provider IS NULL;

COMMIT;
