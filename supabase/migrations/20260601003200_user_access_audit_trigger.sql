-- Server-side audit timestamps for user_access.
-- Populates enabled_at / disabled_at on insert + on is_enabled flips
-- so admin clients no longer have to send device clock values.

CREATE OR REPLACE FUNCTION private.user_access_set_audit_timestamps()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.is_enabled THEN
      NEW.enabled_at := COALESCE(NEW.enabled_at, now());
      NEW.disabled_at := NULL;
    ELSE
      NEW.disabled_at := COALESCE(NEW.disabled_at, now());
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE: only react when is_enabled actually changes.
  IF NEW.is_enabled IS DISTINCT FROM OLD.is_enabled THEN
    IF NEW.is_enabled THEN
      NEW.enabled_at := COALESCE(NEW.enabled_at, now());
      NEW.disabled_at := NULL;
      NEW.disabled_reason := NULL;
    ELSE
      NEW.disabled_at := COALESCE(NEW.disabled_at, now());
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_access_audit_timestamps ON public.user_access;
CREATE TRIGGER user_access_audit_timestamps
BEFORE INSERT OR UPDATE OF is_enabled ON public.user_access
FOR EACH ROW
EXECUTE FUNCTION private.user_access_set_audit_timestamps();
