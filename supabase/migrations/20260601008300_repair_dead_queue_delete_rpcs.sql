BEGIN;

CREATE OR REPLACE FUNCTION "private"."admin_delete_dead_source_queue"("p_queue_id" bigint) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_deleted int;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  DELETE FROM public.source_scrape_queue
  WHERE id = p_queue_id AND status = 'dead';
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RETURN v_deleted > 0;
END;
$$;

ALTER FUNCTION "private"."admin_delete_dead_source_queue"("p_queue_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."admin_delete_dead_tag_queue"("p_queue_id" bigint) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_deleted int;
BEGIN
  IF NOT private.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  DELETE FROM public.event_tag_queue
  WHERE id = p_queue_id AND status = 'dead';
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RETURN v_deleted > 0;
END;
$$;

ALTER FUNCTION "private"."admin_delete_dead_tag_queue"("p_queue_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_delete_dead_source_queue"("p_queue_id" bigint) RETURNS boolean
    LANGUAGE "sql" SECURITY INVOKER
    SET "search_path" TO ''
    AS $$ SELECT private.admin_delete_dead_source_queue(p_queue_id); $$;

ALTER FUNCTION "public"."admin_delete_dead_source_queue"("p_queue_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_delete_dead_tag_queue"("p_queue_id" bigint) RETURNS boolean
    LANGUAGE "sql" SECURITY INVOKER
    SET "search_path" TO ''
    AS $$ SELECT private.admin_delete_dead_tag_queue(p_queue_id); $$;

ALTER FUNCTION "public"."admin_delete_dead_tag_queue"("p_queue_id" bigint) OWNER TO "postgres";


REVOKE ALL ON FUNCTION "private"."admin_delete_dead_source_queue"("p_queue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."admin_delete_dead_source_queue"("p_queue_id" bigint) TO "service_role";
GRANT ALL ON FUNCTION "private"."admin_delete_dead_source_queue"("p_queue_id" bigint) TO "authenticated";


REVOKE ALL ON FUNCTION "private"."admin_delete_dead_tag_queue"("p_queue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."admin_delete_dead_tag_queue"("p_queue_id" bigint) TO "service_role";
GRANT ALL ON FUNCTION "private"."admin_delete_dead_tag_queue"("p_queue_id" bigint) TO "authenticated";


REVOKE ALL ON FUNCTION "public"."admin_delete_dead_source_queue"("p_queue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_delete_dead_source_queue"("p_queue_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_delete_dead_source_queue"("p_queue_id" bigint) TO "service_role";


REVOKE ALL ON FUNCTION "public"."admin_delete_dead_tag_queue"("p_queue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_delete_dead_tag_queue"("p_queue_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_delete_dead_tag_queue"("p_queue_id" bigint) TO "service_role";

DO $$
BEGIN
  IF to_regprocedure('public.admin_delete_dead_source_queue(bigint)') IS NULL THEN
    RAISE EXCEPTION 'admin_delete_dead_source_queue public RPC was not created';
  END IF;
  IF to_regprocedure('public.admin_delete_dead_tag_queue(bigint)') IS NULL THEN
    RAISE EXCEPTION 'admin_delete_dead_tag_queue public RPC was not created';
  END IF;
  IF to_regprocedure('private.admin_delete_dead_source_queue(bigint)') IS NULL THEN
    RAISE EXCEPTION 'admin_delete_dead_source_queue private RPC was not created';
  END IF;
  IF to_regprocedure('private.admin_delete_dead_tag_queue(bigint)') IS NULL THEN
    RAISE EXCEPTION 'admin_delete_dead_tag_queue private RPC was not created';
  END IF;

  RAISE NOTICE 'admin_delete_dead_*_queue RPCs verified';
END $$;

COMMIT;
