-- Add covering indexes for the two unindexed foreign keys on ai_feature_config.
-- Required for efficient referential integrity checks when the referenced rows
-- (approved_ai_models or auth.users) are updated or deleted.

CREATE INDEX IF NOT EXISTS ai_feature_config_model_id_idx
  ON public.ai_feature_config (model_id);

CREATE INDEX IF NOT EXISTS ai_feature_config_updated_by_idx
  ON public.ai_feature_config (updated_by);
