-- Rollback for 20260601011001_fix_provider_constraint.sql
--
-- 011001 was a FIXUP for a partial application of 011000. Its net forward
-- effect over the already-partially-applied state was idempotent re-assertion
-- of two CHECK constraints (the columns + DROP NOT NULL had already landed in
-- the partial 011000 run, and 011001 re-asserts them harmlessly):
--   - event_image_attributions_provider_fields_check (dropped then re-added)
--   - event_image_attributions_provider_check        (dropped then re-added to
--                                                      provider IN ('pexels','pixabay','unsplash'))
--   - DROP NOT NULL on 6 unsplash_* columns, wrapped in idempotent DO blocks
--
-- ROLLBACK ORDERING (rollbacks run NEWEST-first → this file runs BEFORE
-- 20260601011000_add_pexels_pixabay_providers_down.sql):
--   This file only DROPS the two CHECK constraints that 011001 added. It does
--   NOT restore the prior provider_check, does NOT re-add NOT NULL, and does
--   NOT drop the pexels/pixabay columns. All of that full reversal to the
--   pre-011000 state is owned by 011000_down, which runs immediately after.
--   Keeping this file minimal avoids double-error / double-work when both
--   rollbacks execute in sequence.
--
--   Both this file and 011000_down use DROP CONSTRAINT IF EXISTS, so running
--   them back-to-back is safe regardless of which constraints are still present.
--
-- PRIOR DEFINITIONS / SOURCES:
--   - 011001 UP: supabase/migrations/20260601011001_fix_provider_constraint.sql:7-89
--   - Constraints added by 011001 mirror those in
--     supabase/migrations/20260601011000_add_pexels_pixabay_providers.sql:19-21,47-68
--
-- STOP / IRREVERSIBILITY: none for this file. It only drops constraints that
--   011001 created; it intentionally leaves data and columns alone (011000_down
--   handles the data-conditional NOT NULL restore and column drops).

BEGIN;

-- Drop the provider-fields CHECK re-added by 011001.
ALTER TABLE public.event_image_attributions
  DROP CONSTRAINT IF EXISTS event_image_attributions_provider_fields_check;

-- Drop the multi-provider CHECK re-added by 011001.
-- The prior single-provider constraint (CHECK (provider = 'unsplash')) is
-- restored by 011000_down, which runs immediately after this file.
ALTER TABLE public.event_image_attributions
  DROP CONSTRAINT IF EXISTS event_image_attributions_provider_check;

COMMIT;
