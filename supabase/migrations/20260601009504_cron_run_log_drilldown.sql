BEGIN;

ALTER TABLE private.railway_cron_runs
  ADD COLUMN IF NOT EXISTS run_key uuid NOT NULL DEFAULT gen_random_uuid();

CREATE UNIQUE INDEX IF NOT EXISTS railway_cron_runs_run_key_key
  ON private.railway_cron_runs (run_key);

CREATE TABLE IF NOT EXISTS private.cron_run_log_entries (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_key uuid NOT NULL,
  label text NOT NULL,
  provider text NOT NULL CHECK (provider IN ('railway', 'supabase')),
  level text NOT NULL CHECK (level IN ('debug', 'info', 'log', 'warn', 'error')),
  message text NOT NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  sequence integer,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE private.cron_run_log_entries ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS cron_run_log_entries_run_key_created_at_idx
  ON private.cron_run_log_entries (run_key, created_at, id);

CREATE INDEX IF NOT EXISTS cron_run_log_entries_label_created_at_idx
  ON private.cron_run_log_entries (label, created_at DESC);

REVOKE ALL ON TABLE private.cron_run_log_entries FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE private.cron_run_log_entries_id_seq FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.log_cron_run_event(
  p_run_key uuid,
  p_label text,
  p_provider text,
  p_level text,
  p_message text,
  p_metadata jsonb DEFAULT '{}'::jsonb,
  p_sequence integer DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
BEGIN
  INSERT INTO private.cron_run_log_entries (
    run_key,
    label,
    provider,
    level,
    message,
    metadata,
    sequence
  )
  VALUES (
    p_run_key,
    left(p_label, 120),
    p_provider,
    p_level,
    left(p_message, 10000),
    COALESCE(p_metadata, '{}'::jsonb),
    p_sequence
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.log_cron_run_event(
  p_run_key uuid,
  p_label text,
  p_provider text,
  p_level text,
  p_message text,
  p_metadata jsonb DEFAULT '{}'::jsonb,
  p_sequence integer DEFAULT NULL
)
RETURNS void
LANGUAGE sql
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT private.log_cron_run_event(
    p_run_key,
    p_label,
    p_provider,
    p_level,
    p_message,
    p_metadata,
    p_sequence
  );
$$;

DROP FUNCTION IF EXISTS public.log_railway_cron_run(text, text, integer, integer, text);
DROP FUNCTION IF EXISTS public.log_railway_cron_run(text, text, integer, integer, text, uuid, text);
DROP FUNCTION IF EXISTS private.log_railway_cron_run(text, text, integer, integer, text);
DROP FUNCTION IF EXISTS private.log_railway_cron_run(text, text, integer, integer, text, uuid, text);

CREATE FUNCTION private.log_railway_cron_run(
  p_label text,
  p_status text,
  p_http_status integer DEFAULT NULL::integer,
  p_duration_s integer DEFAULT NULL::integer,
  p_body text DEFAULT NULL::text,
  p_run_key uuid DEFAULT gen_random_uuid(),
  p_runner_log text DEFAULT NULL::text
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_id bigint;
  v_run_key uuid := COALESCE(p_run_key, gen_random_uuid());
BEGIN
  INSERT INTO private.railway_cron_runs (
    label,
    status,
    http_status,
    duration_s,
    body,
    run_key
  )
  VALUES (
    left(p_label, 120),
    p_status,
    p_http_status,
    p_duration_s,
    p_body,
    v_run_key
  )
  RETURNING id INTO v_id;

  PERFORM private.log_cron_run_event(
    v_run_key,
    p_label,
    'railway',
    CASE WHEN p_status = 'succeeded' THEN 'info' ELSE 'error' END,
    'runner completed',
    jsonb_strip_nulls(jsonb_build_object(
      'http_status', p_http_status,
      'duration_s', p_duration_s,
      'body', p_body,
      'runner_log', p_runner_log
    )),
    NULL
  );

  RETURN v_id;
END;
$$;

CREATE FUNCTION public.log_railway_cron_run(
  p_label text,
  p_status text,
  p_http_status integer DEFAULT NULL::integer,
  p_duration_s integer DEFAULT NULL::integer,
  p_body text DEFAULT NULL::text,
  p_run_key uuid DEFAULT gen_random_uuid(),
  p_runner_log text DEFAULT NULL::text
)
RETURNS bigint
LANGUAGE sql
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT private.log_railway_cron_run(
    p_label,
    p_status,
    p_http_status,
    p_duration_s,
    p_body,
    p_run_key,
    p_runner_log
  );
$$;

CREATE OR REPLACE FUNCTION private.railway_cron_run_detail(p_run_id bigint)
RETURNS TABLE (
  id bigint,
  run_key uuid,
  label text,
  status text,
  http_status integer,
  duration_s integer,
  body text,
  ran_at timestamptz,
  logs jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
BEGIN
  IF current_user <> 'service_role' AND NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    r.id,
    r.run_key,
    r.label,
    r.status,
    r.http_status,
    r.duration_s,
    r.body,
    r.ran_at,
    COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'id', l.id,
            'provider', l.provider,
            'level', l.level,
            'message', l.message,
            'metadata', l.metadata,
            'sequence', l.sequence,
            'created_at', l.created_at
          )
          ORDER BY l.created_at, l.id
        )
        FROM private.cron_run_log_entries l
        WHERE l.run_key = r.run_key
      ),
      '[]'::jsonb
    ) AS logs
  FROM private.railway_cron_runs r
  WHERE r.id = p_run_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_railway_cron_run_detail(p_run_id bigint)
RETURNS TABLE (
  id bigint,
  run_key uuid,
  label text,
  status text,
  http_status integer,
  duration_s integer,
  body text,
  ran_at timestamptz,
  logs jsonb
)
LANGUAGE sql
SECURITY INVOKER
SET search_path TO ''
AS $$
  SELECT * FROM private.railway_cron_run_detail(p_run_id);
$$;

REVOKE EXECUTE ON FUNCTION private.log_cron_run_event(uuid, text, text, text, text, jsonb, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.log_cron_run_event(uuid, text, text, text, text, jsonb, integer)
  TO service_role;

REVOKE EXECUTE ON FUNCTION public.log_cron_run_event(uuid, text, text, text, text, jsonb, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.log_cron_run_event(uuid, text, text, text, text, jsonb, integer)
  TO service_role;

REVOKE EXECUTE ON FUNCTION private.log_railway_cron_run(text, text, integer, integer, text, uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.log_railway_cron_run(text, text, integer, integer, text, uuid, text)
  TO service_role;

REVOKE EXECUTE ON FUNCTION public.log_railway_cron_run(text, text, integer, integer, text, uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.log_railway_cron_run(text, text, integer, integer, text, uuid, text)
  TO service_role;

REVOKE EXECUTE ON FUNCTION private.railway_cron_run_detail(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.railway_cron_run_detail(bigint)
  TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.admin_railway_cron_run_detail(bigint)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_railway_cron_run_detail(bigint)
  TO authenticated, service_role;

COMMIT;
