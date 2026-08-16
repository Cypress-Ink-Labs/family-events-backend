-- Rollback for 20260816001000_redrive_constraint_bug_dead_letters.sql
--
-- Drops the one-shot redrive helper. Rows already redriven stay redriven —
-- reverting queue state would re-dead-letter sources that may have since
-- processed successfully.

DROP FUNCTION IF EXISTS private.redrive_constraint_bug_dead_letters(boolean);
