CREATE OR REPLACE FUNCTION private.broadcast_admin_event_changes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM realtime.broadcast_changes(
    'events:all',
    TG_OP,
    TG_OP,
    TG_TABLE_NAME,
    TG_TABLE_SCHEMA,
    NEW,
    OLD
  );

  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS broadcast_admin_event_changes_trigger ON public.events;

CREATE TRIGGER broadcast_admin_event_changes_trigger
AFTER INSERT OR UPDATE OR DELETE ON public.events
FOR EACH ROW
EXECUTE FUNCTION private.broadcast_admin_event_changes();

DROP POLICY IF EXISTS "Admins can receive dashboard realtime" ON realtime.messages;

CREATE POLICY "Admins can receive dashboard realtime"
ON realtime.messages
FOR SELECT
TO authenticated
USING (
  topic IN ('events:all', 'dashboard:events')
  AND (SELECT private.is_admin())
);
