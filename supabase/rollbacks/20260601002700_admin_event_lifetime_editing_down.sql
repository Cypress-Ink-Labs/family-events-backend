DROP FUNCTION IF EXISTS public.admin_unlock_event_fields(uuid);
DROP FUNCTION IF EXISTS private.admin_unlock_event_fields(uuid);
DROP FUNCTION IF EXISTS public.admin_create_event(jsonb, uuid[]);
DROP FUNCTION IF EXISTS private.admin_create_event(jsonb, uuid[]);
DROP FUNCTION IF EXISTS public.admin_update_event(uuid, jsonb, uuid[], boolean);
DROP FUNCTION IF EXISTS private.admin_update_event(uuid, jsonb, uuid[], boolean);
DROP FUNCTION IF EXISTS private.admin_validate_event_patch(jsonb);

DROP INDEX IF EXISTS public.events_admin_last_edited_at_idx;

ALTER TABLE public.events
  DROP COLUMN IF EXISTS admin_last_edited_by,
  DROP COLUMN IF EXISTS admin_last_edited_at,
  DROP COLUMN IF EXISTS admin_locked_fields;
