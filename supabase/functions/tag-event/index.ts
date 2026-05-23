import "@supabase/functions-js/edge-runtime.d.ts";
import { handleTagEvent } from "./handler.ts";

Deno.serve(handleTagEvent);
