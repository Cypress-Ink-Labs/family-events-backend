-- Fix migration state after partial application of 20260601011000
-- The columns exist but the constraint failed to apply.

BEGIN;

-- Drop old constraint if it exists (from earlier partial run)
ALTER TABLE public.event_image_attributions 
  DROP CONSTRAINT IF EXISTS event_image_attributions_provider_fields_check;

-- Re-add the provider check allowing all three
ALTER TABLE public.event_image_attributions 
  DROP CONSTRAINT IF EXISTS event_image_attributions_provider_check;

ALTER TABLE public.event_image_attributions 
  ADD CONSTRAINT event_image_attributions_provider_check 
  CHECK (provider IN ('pexels', 'pixabay', 'unsplash'));

-- Make Unsplash columns nullable (only required when provider='unsplash')
DO $$
BEGIN
  ALTER TABLE public.event_image_attributions 
    ALTER COLUMN unsplash_photo_id DROP NOT NULL;
EXCEPTION
  WHEN others THEN NULL;  -- Already nullable
END $$;

DO $$
BEGIN
  ALTER TABLE public.event_image_attributions 
    ALTER COLUMN unsplash_photographer_name DROP NOT NULL;
EXCEPTION
  WHEN others THEN NULL;
END $$;

DO $$
BEGIN
  ALTER TABLE public.event_image_attributions 
    ALTER COLUMN unsplash_photographer_username DROP NOT NULL;
EXCEPTION
  WHEN others THEN NULL;
END $$;

DO $$
BEGIN
  ALTER TABLE public.event_image_attributions 
    ALTER COLUMN unsplash_photographer_profile_url DROP NOT NULL;
EXCEPTION
  WHEN others THEN NULL;
END $$;

DO $$
BEGIN
  ALTER TABLE public.event_image_attributions 
    ALTER COLUMN unsplash_photo_url DROP NOT NULL;
EXCEPTION
  WHEN others THEN NULL;
END $$;

DO $$
BEGIN
  ALTER TABLE public.event_image_attributions 
    ALTER COLUMN unsplash_download_location DROP NOT NULL;
EXCEPTION
  WHEN others THEN NULL;
END $$;

-- Add check constraint: provider-specific columns must be populated
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

COMMIT;
