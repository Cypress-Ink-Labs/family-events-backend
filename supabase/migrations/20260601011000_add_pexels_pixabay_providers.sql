-- Add Pexels and Pixabay as supported image attribution providers
--
-- Motivation: We're hitting Unsplash rate limits (50/hour free tier).
-- Pexels offers 200/hour → unlimited (free after approval) and Pixabay
-- offers 6,000/hour with no monthly cap. This migration adds columns for
-- those providers and updates the provider enum to support all three.
--
-- Backwards compatibility: Existing Unsplash rows remain untouched.
-- New Pexels/Pixabay rows use provider-specific columns; Unsplash columns
-- remain NOT NULL only for provider='unsplash' rows (enforced by trigger).

BEGIN;

-- 1. Drop the old provider check constraint
ALTER TABLE public.event_image_attributions 
  DROP CONSTRAINT IF EXISTS event_image_attributions_provider_check;

-- 2. Add new provider check allowing pexels, pixabay, unsplash
ALTER TABLE public.event_image_attributions 
  ADD CONSTRAINT event_image_attributions_provider_check 
  CHECK (provider IN ('pexels', 'pixabay', 'unsplash'));

-- 3. Make Unsplash columns nullable (only required when provider='unsplash')
ALTER TABLE public.event_image_attributions 
  ALTER COLUMN unsplash_photo_id DROP NOT NULL,
  ALTER COLUMN unsplash_photographer_name DROP NOT NULL,
  ALTER COLUMN unsplash_photographer_username DROP NOT NULL,
  ALTER COLUMN unsplash_photographer_profile_url DROP NOT NULL,
  ALTER COLUMN unsplash_photo_url DROP NOT NULL,
  ALTER COLUMN unsplash_download_location DROP NOT NULL;

-- 4. Add Pexels attribution columns
ALTER TABLE public.event_image_attributions
  ADD COLUMN IF NOT EXISTS pexels_photo_id text,
  ADD COLUMN IF NOT EXISTS pexels_photographer_name text,
  ADD COLUMN IF NOT EXISTS pexels_photographer_profile_url text,
  ADD COLUMN IF NOT EXISTS pexels_photo_url text;

-- 5. Add Pixabay attribution columns  
ALTER TABLE public.event_image_attributions
  ADD COLUMN IF NOT EXISTS pixabay_photo_id text,
  ADD COLUMN IF NOT EXISTS pixabay_photographer_name text,
  ADD COLUMN IF NOT EXISTS pixabay_photographer_username text,
  ADD COLUMN IF NOT EXISTS pixabay_photo_url text;

-- 6. Add check constraint: provider-specific columns must be populated
ALTER TABLE public.event_image_attributions
  ADD CONSTRAINT event_image_attributions_provider_fields_check
  CHECK (
    (provider = 'unsplash' AND 
      unsplash_photo_id IS NOT NULL AND
      unsplash_photographer_name IS NOT NULL AND
      unsplash_photographer_username IS NOT NULL AND
      unsplash_photographer_profile_url IS NOT NULL AND
      unsplash_photo_url IS NOT NULL AND
      unsplash_download_location IS NOT NULL)
    OR
    (provider = 'pexels' AND
      pexels_photo_id IS NOT NULL AND
      pexels_photographer_name IS NOT NULL AND
      pexels_photographer_profile_url IS NOT NULL AND
      pexels_photo_url IS NOT NULL)
    OR
    (provider = 'pixabay' AND
      pixabay_photo_id IS NOT NULL AND
      pixabay_photographer_name IS NOT NULL AND
      pixabay_photo_url IS NOT NULL)
  );

-- 7. Comment the table for documentation
COMMENT ON TABLE public.event_image_attributions IS 
  'Stock image attribution records for events. Supports Pexels (primary), Pixabay (backup), and Unsplash (legacy). Provider-specific columns are nullable but enforced via CHECK constraint based on provider field.';

COMMENT ON COLUMN public.event_image_attributions.provider IS 
  'Stock image provider: pexels (200/hr → unlimited free), pixabay (6K/hr free), or unsplash (50/hr free, legacy)';

COMMIT;
