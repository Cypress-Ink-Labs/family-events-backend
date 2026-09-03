-- Keep the latest admin_events_enriched signature and body intact while
-- correcting the same invalid two-character ILIKE escape fixed for facets in
-- 20260902000000. pg_get_functiondef avoids duplicating the 43-column return
-- contract in another migration.
DO $migration$
DECLARE
  function_signature regprocedure :=
    'private.admin_events_enriched(text,uuid,boolean,text,timestamptz,uuid,integer,public.llm_event_review_status,public.llm_event_review_decision,boolean,uuid)'::regprocedure;
  previous_definition text;
  corrected_definition text;
BEGIN
  SELECT pg_get_functiondef(function_signature) INTO previous_definition;
  corrected_definition := replace(
    previous_definition,
    $old$replace(replace(replace(btrim(p_keyword), '\\', '\\\\'), '%', '\\%'), '_', '\\_')$old$,
    $new$replace(replace(replace(btrim(p_keyword), E'\\', E'\\\\'), '%', E'\\%'), '_', E'\\_')$new$
  );
  corrected_definition := replace(
    corrected_definition,
    $old$ ESCAPE '\\'$old$,
    $new$ ESCAPE E'\\'$new$
  );

  IF corrected_definition = previous_definition
    OR position($old$ ESCAPE '\\'$old$ IN corrected_definition) > 0
  THEN
    RAISE EXCEPTION 'admin_events_enriched escape patch did not match expected definition';
  END IF;

  EXECUTE corrected_definition;
END;
$migration$;
