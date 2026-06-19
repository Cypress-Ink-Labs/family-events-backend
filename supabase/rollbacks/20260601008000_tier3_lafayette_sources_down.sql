-- Rollback for 20260601008000_tier3_lafayette_sources.sql
--
-- UP migration effects (file 20260601008000_tier3_lafayette_sources.sql):
--   1. lines 11-26: DROP + re-ADD public.event_sources_source_type_check,
--      defining the 9-value array
--      (website, ical, rss, manual, macaronikid, brec, downtownlafayette,
--       lcglafayette, localhop).
--   2. lines 29-75: INSERT 2 event_sources rows via SELECT ... JOIN cities
--      (slug='lafayette'), ON CONFLICT (url) DO UPDATE:
--        - Downtown Lafayette (DDA)  url=https://www.downtownlafayette.org/events
--        - LCG Events                url=https://www.lafayettela.gov/your-government/events-calendar/
--
-- Prior-definition source for the constraint:
--   20260601000000_schema_baseline.sql:4424 — the squashed baseline ALREADY
--   contains the identical full 9-value array (website, ical, rss, manual,
--   macaronikid, brec, downtownlafayette, lcglafayette, localhop). The only
--   intervening migration with a SMALLER timestamp than 008000 is
--   20260601007000_lafayette_new_sources.sql, which does NOT touch this
--   constraint. (20260601025000_baton_rouge_sources.sql also rewrites this
--   constraint but is LATER — ignored here.)
--
--   => The "prior" array equals the post-008000 array. The UP migration's
--      constraint swap is therefore a REDUNDANT re-add (it dropped a constraint
--      that already had all 9 values and re-added the same 9 values). This
--      rollback restores that same baseline array, so the constraint step is
--      effectively a no-op re-add. It is kept for symmetry / determinism: it
--      guarantees the constraint is present with the baseline definition even
--      if the UP migration's DROP had left it absent.
--
-- Ordering: re-add the constraint AFTER deleting the inserted rows is NOT
-- required (the deleted rows already satisfy the constraint), but we DROP+ADD
-- the constraint last so that, if a future re-introduction of stricter values
-- is layered in, the surviving rows are validated against the restored array.
--
-- IRREVERSIBILITY FLAGS:
--   * ON CONFLICT (url) DO UPDATE: if either of the 2 URLs already existed as an
--     event_sources row BEFORE this migration ran (e.g. seeded manually or via a
--     prior re-run), the UP migration OVERWROTE that row's name/source_type/
--     scrape_interval_hours/notes/updated_at with the migration's values. A
--     DELETE cannot recover the pre-migration column values for such a row, and
--     would additionally remove a row that predated the migration. Both URLs are
--     absent from the baseline and all earlier migrations, so the EXPECTED case
--     is that these 2 rows were INTRODUCED by 008000 and the DELETE is exact.
--     Verify with the present-before checklist below before running.
--   * The constraint step is otherwise fully reversible (prior def found at
--     baseline:4424 and restored verbatim).

BEGIN;

-- 1. Remove the 2 sources introduced by this migration.
--    Exact URL match (the UP migration's ON CONFLICT key is url).
DELETE FROM public.event_sources
WHERE url IN (
  'https://www.downtownlafayette.org/events',
  'https://www.lafayettela.gov/your-government/events-calendar/'
);

-- 2. Restore the source_type check constraint to its prior (baseline) definition.
--    Source: 20260601000000_schema_baseline.sql:4424 — identical 9-value array.
--    This is a redundant re-add (see header): the array is unchanged from the
--    post-008000 state. Kept for determinism / to guarantee the constraint exists.
ALTER TABLE public.event_sources
  DROP CONSTRAINT IF EXISTS "event_sources_source_type_check";

ALTER TABLE public.event_sources
  ADD CONSTRAINT "event_sources_source_type_check"
  CHECK (source_type = ANY (ARRAY[
    'website'::text,
    'ical'::text,
    'rss'::text,
    'manual'::text,
    'macaronikid'::text,
    'brec'::text,
    'downtownlafayette'::text,
    'lcglafayette'::text,
    'localhop'::text
  ]));

COMMIT;
