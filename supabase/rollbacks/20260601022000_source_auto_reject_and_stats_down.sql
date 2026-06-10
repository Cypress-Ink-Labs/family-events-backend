-- Rollback for 20260601022000_source_auto_reject_and_stats.sql
-- Reverts:
--   - private.should_auto_reject_source(uuid,float,int,int) + public wrapper
--   - private.pipeline_learning_stats(int) + public wrapper
-- Data-loss caveat: none — function-only changes, no table or data modifications.

BEGIN;

DROP FUNCTION IF EXISTS public.pipeline_learning_stats(integer);
DROP FUNCTION IF EXISTS private.pipeline_learning_stats(integer);
DROP FUNCTION IF EXISTS public.should_auto_reject_source(uuid, float, integer, integer);
DROP FUNCTION IF EXISTS private.should_auto_reject_source(uuid, float, integer, integer);

COMMIT;
