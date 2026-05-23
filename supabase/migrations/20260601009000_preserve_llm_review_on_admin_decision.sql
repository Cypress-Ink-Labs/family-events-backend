-- Preserve LLM review data after admin publishes/rejects so the audit trail
-- remains visible.  Only flip the status to 'not_required'; keep all other
-- fields (decision, confidence, reason, flags, provider, model, etc.) intact.

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
    NEW.llm_review_status := 'not_required';
  END IF;

  RETURN NEW;
END;
$$;
