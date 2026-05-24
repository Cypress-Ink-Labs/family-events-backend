-- Add GPT-5.x model family. These supersede GPT-4.x for both tagging and review.
-- gpt-5.4-nano: $0.20/$1.25 per 1M — purpose-built for classification/extraction (tagging)
-- gpt-5.4-mini: $0.75/$4.50 per 1M — stronger mini for high-volume review
-- gpt-5.4:      $2.50/$15.00 per 1M — frontier model with configurable reasoning (event review)
-- gpt-5.5:      $5.00/$30.00 per 1M — overkill for this workload, added disabled

INSERT INTO public.approved_ai_models (id, provider, display_name, description, cost_tier)
VALUES
  ('gpt-5.4-nano', 'openai', 'GPT-5.4 Nano',
   'Purpose-built for classification, data extraction, and ranking. Best default for high-volume tagging. $0.20/$1.25 per 1M.',
   'low'),
  ('gpt-5.4-mini', 'openai', 'GPT-5.4 mini',
   'Strongest mini model for coding and subagents. Good mid-tier option for review. $0.75/$4.50 per 1M.',
   'low'),
  ('gpt-5.4', 'openai', 'GPT-5.4',
   'Frontier model with configurable reasoning effort (none→extra-high) and 1M context. Best for nuanced event review. $2.50/$15 per 1M.',
   'high'),
  ('gpt-5.5', 'openai', 'GPT-5.5',
   'Highest intelligence class. Overkill for tagging/review at $5/$30 per 1M. Disabled by default.',
   'high')
ON CONFLICT (id) DO UPDATE SET
  provider     = EXCLUDED.provider,
  display_name = EXCLUDED.display_name,
  description  = EXCLUDED.description,
  cost_tier    = EXCLUDED.cost_tier;

-- gpt-5.5 is available but disabled — too expensive for routine workloads
UPDATE public.approved_ai_models SET is_enabled = false WHERE id = 'gpt-5.5';

-- Mark legacy 4.x models as disabled since 5.x supersedes them.
UPDATE public.approved_ai_models
SET is_enabled = false
WHERE id IN ('gpt-4.1-nano', 'gpt-4.1-mini', 'gpt-4.1', 'gpt-4o', 'gpt-4o-mini');

-- Update ai_feature_config defaults to the new 5.x equivalents.
-- ON CONFLICT skipped — update only if the config exists and still points to a now-disabled model.
INSERT INTO public.ai_feature_config (feature, model_id, enabled)
VALUES
  ('tagging',      'gpt-5.4-nano', true),
  ('event-review', 'gpt-5.4',      false)
ON CONFLICT (feature) DO UPDATE SET
  model_id = EXCLUDED.model_id
WHERE public.ai_feature_config.model_id IN (
  'gpt-4.1-nano', 'gpt-4.1-mini', 'gpt-4.1', 'gpt-4o', 'gpt-4o-mini'
);
