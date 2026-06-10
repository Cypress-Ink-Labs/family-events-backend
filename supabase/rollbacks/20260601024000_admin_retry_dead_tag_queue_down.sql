-- Rollback for 20260601024000_admin_retry_dead_tag_queue.sql
-- Reverts:
--   - private.admin_retry_dead_tag_queue(bigint) new function + grants
--   - public.admin_retry_dead_tag_queue(bigint) new wrapper + grants
--   - CREATE OR REPLACE of private.admin_retry_source_scrape_queue(bigint) (body unchanged, safe to leave)
--   - CREATE OR REPLACE of private.admin_retry_tag_queue(uuid) (body unchanged, safe to leave)
-- Note: 024000 used CREATE OR REPLACE on admin_retry_source_scrape_queue and
--   admin_retry_tag_queue with identical bodies to the baseline — no net change,
--   no restoration needed for those two.
-- Data-loss caveat: none — function-only changes.

BEGIN;

DROP FUNCTION IF EXISTS public.admin_retry_dead_tag_queue(bigint);
DROP FUNCTION IF EXISTS private.admin_retry_dead_tag_queue(bigint);

COMMIT;
