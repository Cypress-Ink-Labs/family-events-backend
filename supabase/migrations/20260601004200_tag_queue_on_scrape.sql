-- Switch tag-queue processing from a polling cron to a push-based trigger.
--
-- scrape-source now calls invoke_process_tag_queue() via RPC at the end of
-- every successful import, so the worker fires immediately when there is
-- actual work. The pg_cron job is kept as a 15-minute fallback to handle:
--   - reclassify / manual-review items queued outside the scrape path
--   - anything missed if the RPC call failed silently
--
-- Was: '* * * * *' (every minute) — caused empty polls and overlapping batches
-- Now: '*/15 * * * *' (every 15 min) — safety net only

DO $$
BEGIN
  BEGIN
    PERFORM cron.unschedule('process-tag-queue');
  EXCEPTION
    WHEN undefined_object THEN NULL;
    WHEN OTHERS THEN
      RAISE WARNING 'Unexpected error unscheduling process-tag-queue: %', SQLERRM;
  END;
  PERFORM cron.schedule(
    'process-tag-queue',
    '*/15 * * * *',
    $sql$SELECT public.invoke_process_tag_queue();$sql$
  );
END $$;
