-- Rollback for 20260610162002_enqueue_source_scrape_rpc.sql
-- Reverts:
--   - DROP public.enqueue_source_scrape(uuid, text)
--   - DROP private.enqueue_source_scrape(uuid, text)

BEGIN;

-- 1. Drop public wrapper first (it calls the private function).
DROP FUNCTION IF EXISTS public.enqueue_source_scrape(uuid, text);

-- 2. Drop private implementation.
DROP FUNCTION IF EXISTS private.enqueue_source_scrape(uuid, text);

COMMIT;
