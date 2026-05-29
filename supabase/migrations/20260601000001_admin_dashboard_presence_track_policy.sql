DROP POLICY IF EXISTS "Admins can track dashboard presence" ON realtime.messages;

CREATE POLICY "Admins can track dashboard presence"
ON realtime.messages
FOR INSERT
TO authenticated
WITH CHECK (
  topic = 'dashboard:events'
  AND extension = 'presence'
  AND (SELECT private.is_admin())
);
