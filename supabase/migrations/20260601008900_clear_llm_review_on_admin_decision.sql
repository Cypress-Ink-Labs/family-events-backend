-- When an admin publishes or rejects an event the LLM review state becomes
-- stale. Clear it so the UI no longer shows a confusing "Needs review" or
-- "LLM approved" badge next to a manually-decided event.

CREATE OR REPLACE FUNCTION private.clear_llm_review_on_status_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status
     AND NEW.status IN ('published', 'rejected')
     AND OLD.status = 'draft'
  THEN
    NEW.llm_review_status        := 'not_required';
    NEW.llm_review_decision      := NULL;
    NEW.llm_review_confidence    := NULL;
    NEW.llm_review_reason        := NULL;
    NEW.llm_review_flags         := '{}'::text[];
    NEW.llm_review_error         := NULL;
    NEW.llm_review_model         := NULL;
    NEW.llm_review_provider      := NULL;
    NEW.llm_review_prompt_version := NULL;
    NEW.llm_reviewed_at          := NULL;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_clear_llm_review_on_status_change ON public.events;

CREATE TRIGGER trg_clear_llm_review_on_status_change
  BEFORE UPDATE OF status ON public.events
  FOR EACH ROW
  EXECUTE FUNCTION private.clear_llm_review_on_status_change();

-- Fix existing published/rejected events that still carry stale LLM review data
UPDATE public.events
SET llm_review_status         = 'not_required',
    llm_review_decision       = NULL,
    llm_review_confidence     = NULL,
    llm_review_reason         = NULL,
    llm_review_flags          = '{}'::text[],
    llm_review_error          = NULL,
    llm_review_model          = NULL,
    llm_review_provider       = NULL,
    llm_review_prompt_version = NULL,
    llm_reviewed_at           = NULL,
    updated_at                = now()
WHERE status IN ('published', 'rejected')
  AND llm_review_status IS DISTINCT FROM 'not_required';
