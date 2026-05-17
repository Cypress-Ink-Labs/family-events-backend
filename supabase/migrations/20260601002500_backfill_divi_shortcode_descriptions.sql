-- Backfill: scrub leaked Divi / WordPress shortcodes from events.description.
--
-- Historic ingest sliced the raw JSON-LD description to 500 chars before
-- running cleanDescription, so several `Acadiana Center for the Arts` rows
-- stored a fragment of Divi page-builder source — including a trailing
-- unclosed `[et_pb_image src="..."` that the closed-bracket regex in the
-- read-side sanitizers (FECore.DescriptionSanitizer + packages/shared
-- description-sanitizer.ts) does not match. New ingests are already clean
-- (parser fix in 8103b6b + sanitizer hardening in this PR); this migration
-- repairs rows that landed before those fixes.
--
-- Strategy: re-run the same shortcode strip the runtime sanitizers use, then
-- set the column to NULL whenever the cleaned result is whitespace-only so
-- the "About" section disappears entirely until the next scrape repopulates
-- the row with the full clean prose.

UPDATE events
SET description = nullif(
  btrim(
    regexp_replace(
      regexp_replace(
        regexp_replace(
          regexp_replace(description, '\[/?et_pb_[a-z0-9_]*[^]]*\]', '', 'gi'),
          '\[/?et_pb_[a-z0-9_]*[^]]*$', '', 'i'
        ),
        '\[/?[a-z][a-z0-9_]*([[:space:]][^]]*)?\]', '', 'g'
      ),
      '\[/?[a-z][a-z0-9_]*[[:space:]][^]]*$', '', ''
    )
  ),
  ''
)
WHERE description ~ '\[/?et_pb_';
