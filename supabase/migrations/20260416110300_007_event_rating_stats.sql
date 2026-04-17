/*
  # Event rating stats view

  Replaces client-side aggregation. `enrichEvents` used to fetch ALL rating
  rows for matching events and compute avg/count in JavaScript — with 50
  events * 100 ratings that's 5000 rows over the wire per page load.

  This view returns one row per event with avg + count, computed in Postgres.
*/

CREATE OR REPLACE VIEW event_rating_stats
WITH (security_invoker = true) AS
SELECT
  event_id,
  ROUND(AVG(score)::numeric, 1) AS avg_score,
  COUNT(*)::int AS rating_count
FROM ratings
GROUP BY event_id;

COMMENT ON VIEW event_rating_stats IS
  'Per-event aggregated rating stats. Replaces client-side aggregation in enrichEvents.';

-- Grant read access to both anon (public event pages) and authenticated users
GRANT SELECT ON event_rating_stats TO anon, authenticated;
