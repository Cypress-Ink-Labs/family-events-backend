BEGIN;

DO $rollback$
DECLARE
  function_signature regprocedure :=
    'private.admin_events_enriched(text,uuid,boolean,text,timestamptz,uuid,integer,public.llm_event_review_status,public.llm_event_review_decision,boolean,uuid)'::regprocedure;
  current_definition text;
  previous_definition text;
BEGIN
  SELECT pg_get_functiondef(function_signature) INTO current_definition;
  previous_definition := replace(
    current_definition,
    $old$replace(replace(replace(btrim(p_keyword), E'\\', E'\\\\'), '%', E'\\%'), '_', E'\\_')$old$,
    $new$replace(replace(replace(btrim(p_keyword), '\\', '\\\\'), '%', '\\%'), '_', '\\_')$new$
  );
  previous_definition := replace(
    previous_definition,
    $old$ ESCAPE E'\\'$old$,
    $new$ ESCAPE '\\'$new$
  );

  IF previous_definition = current_definition THEN
    RAISE EXCEPTION 'admin_events_enriched rollback did not match expected definition';
  END IF;

  EXECUTE previous_definition;
END;
$rollback$;

COMMIT;
