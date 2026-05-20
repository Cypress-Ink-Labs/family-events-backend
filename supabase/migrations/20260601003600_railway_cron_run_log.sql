-- Persistent log of Railway cron service executions.
-- Written by the log-cron-run edge function (service_role only).
-- Read by admin RPCs (authenticated only).

CREATE TABLE IF NOT EXISTS private.railway_cron_runs (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  label       text        NOT NULL,
  status      text        NOT NULL CHECK (status IN ('succeeded', 'failed')),
  http_status int,
  duration_s  int,
  body        text,
  ran_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS railway_cron_runs_label_ran_at
  ON private.railway_cron_runs (label, ran_at DESC);

-- ── log_railway_cron_run ────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION private.log_railway_cron_run(
  p_label       text,
  p_status      text,
  p_http_status int  DEFAULT NULL,
  p_duration_s  int  DEFAULT NULL,
  p_body        text DEFAULT NULL
) RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  INSERT INTO private.railway_cron_runs (label, status, http_status, duration_s, body)
  VALUES (p_label, p_status, p_http_status, p_duration_s, p_body);
$$;
GRANT EXECUTE ON FUNCTION private.log_railway_cron_run(text, text, int, int, text)
  TO service_role;

CREATE OR REPLACE FUNCTION public.log_railway_cron_run(
  p_label       text,
  p_status      text,
  p_http_status int  DEFAULT NULL,
  p_duration_s  int  DEFAULT NULL,
  p_body        text DEFAULT NULL
) RETURNS void
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.log_railway_cron_run(p_label, p_status, p_http_status, p_duration_s, p_body);
$$;
REVOKE ALL ON FUNCTION public.log_railway_cron_run(text, text, int, int, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.log_railway_cron_run(text, text, int, int, text)
  TO service_role;

-- ── admin_list_railway_cron_jobs ────────────────────────────────────────────

CREATE OR REPLACE FUNCTION private.list_railway_cron_jobs()
RETURNS TABLE (
  label               text,
  last_run_status     text,
  last_run_at         timestamptz,
  last_run_duration_s int,
  last_http_status    int
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH known AS (
    SELECT unnest(ARRAY[
      'cron-db-maintenance',
      'cron-tag-queue',
      'cron-scrape-sources'
    ]::text[]) AS label
  ),
  last_runs AS (
    SELECT DISTINCT ON (r.label)
      r.label, r.status, r.ran_at, r.duration_s, r.http_status
    FROM private.railway_cron_runs r
    ORDER BY r.label, r.ran_at DESC
  )
  SELECT k.label, lr.status, lr.ran_at, lr.duration_s, lr.http_status
  FROM known k
  LEFT JOIN last_runs lr ON lr.label = k.label
  ORDER BY k.label;
$$;
GRANT EXECUTE ON FUNCTION private.list_railway_cron_jobs()
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_list_railway_cron_jobs()
RETURNS TABLE (
  label               text,
  last_run_status     text,
  last_run_at         timestamptz,
  last_run_duration_s int,
  last_http_status    int
)
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT * FROM private.list_railway_cron_jobs();
$$;
REVOKE ALL ON FUNCTION public.admin_list_railway_cron_jobs() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_railway_cron_jobs()
  TO authenticated;

-- ── admin_railway_cron_run_history ──────────────────────────────────────────

CREATE OR REPLACE FUNCTION private.railway_cron_run_history(
  p_label text DEFAULT NULL,
  p_limit int  DEFAULT 50
)
RETURNS TABLE (
  id          bigint,
  label       text,
  status      text,
  http_status int,
  duration_s  int,
  body        text,
  ran_at      timestamptz
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT id, label, status, http_status, duration_s, body, ran_at
  FROM private.railway_cron_runs
  WHERE p_label IS NULL OR label = p_label
  ORDER BY ran_at DESC
  LIMIT LEAST(p_limit, 200);
$$;
GRANT EXECUTE ON FUNCTION private.railway_cron_run_history(text, int)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_railway_cron_run_history(
  p_label text DEFAULT NULL,
  p_limit int  DEFAULT 50
)
RETURNS TABLE (
  id          bigint,
  label       text,
  status      text,
  http_status int,
  duration_s  int,
  body        text,
  ran_at      timestamptz
)
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT * FROM private.railway_cron_run_history(p_label, p_limit);
$$;
REVOKE ALL ON FUNCTION public.admin_railway_cron_run_history(text, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_railway_cron_run_history(text, int)
  TO authenticated;
