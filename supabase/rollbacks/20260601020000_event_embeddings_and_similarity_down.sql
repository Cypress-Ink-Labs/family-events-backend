-- Rollback for 20260601020000_event_embeddings_and_similarity.sql
-- Reverts:
--   - public.event_embeddings table (and HNSW + event_id indexes, RLS policies, grants)
--   - private.find_similar_events(vector,int,float,uuid,uuid) function + grants
--   - public.find_similar_events(vector,int,float,uuid,uuid) wrapper + grants
--   - ai_feature_config CHECK expansion (adds tag-memory, review-memory, source-auto-reject)
--   - private.upsert_ai_feature_config body replacement (expanded feature list)
--   - INSERT of tag-memory / review-memory / source-auto-reject rows into ai_feature_config
--   - UPDATE of parent-tips model_id to gpt-5.4-nano
-- Data-loss caveat:
--   DROPPING event_embeddings DESTROYS all stored embedding vectors — irreversible.
--   The ai_feature_config rows for tag-memory/review-memory/source-auto-reject are
--   DELETED; any enabled state is lost.
--   The parent-tips model_id is NOT restored (prior value unknown at rollback time).

BEGIN;

-- 1. Drop public + private find_similar_events (reverse dependency order).
DROP FUNCTION IF EXISTS public.find_similar_events(extensions.vector(1536), integer, float, uuid, uuid);
DROP FUNCTION IF EXISTS private.find_similar_events(extensions.vector(1536), integer, float, uuid, uuid);

-- 2. Drop event_embeddings table (cascades policies, indexes, sequence grants).
-- WARNING: destroys all embedding data.
DROP TABLE IF EXISTS public.event_embeddings;

-- 3. Restore the narrower ai_feature_config CHECK (tagging + event-review + parent-tips only).
ALTER TABLE public.ai_feature_config
  DROP CONSTRAINT IF EXISTS ai_feature_config_feature_check;

ALTER TABLE public.ai_feature_config
  ADD CONSTRAINT ai_feature_config_feature_check
  CHECK (feature IN ('tagging', 'event-review', 'parent-tips'));

-- 4. Remove the ai_feature_config rows added by 020000.
DELETE FROM public.ai_feature_config
WHERE feature IN ('tag-memory', 'review-memory', 'source-auto-reject');

-- 5. Restore private.upsert_ai_feature_config to its pre-020000 body.
-- Prior body sourced from 20260601005000_ai_models_and_cron_drilldown.sql (final block).
CREATE OR REPLACE FUNCTION private.upsert_ai_feature_config(
  p_feature  text,
  p_model_id text,
  p_enabled  bool
) RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_feature NOT IN ('tagging', 'event-review') THEN
    RAISE EXCEPTION 'invalid feature: %', p_feature;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.approved_ai_models
    WHERE id = p_model_id AND is_enabled = true
  ) THEN
    RAISE EXCEPTION 'model % not found or disabled', p_model_id;
  END IF;

  INSERT INTO public.ai_feature_config (feature, model_id, enabled, updated_at, updated_by)
  VALUES (p_feature, p_model_id, p_enabled, now(), auth.uid())
  ON CONFLICT (feature) DO UPDATE SET
    model_id   = EXCLUDED.model_id,
    enabled    = EXCLUDED.enabled,
    updated_at = now(),
    updated_by = auth.uid();
END;
$$;

-- Restore grants: service_role only on private (authenticated uses public wrapper).
REVOKE EXECUTE ON FUNCTION private.upsert_ai_feature_config(text, text, bool)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.upsert_ai_feature_config(text, text, bool)
  TO service_role;

COMMIT;
