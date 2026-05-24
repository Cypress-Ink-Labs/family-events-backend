import "@supabase/functions-js/edge-runtime.d.ts";
import { handleGenerateParentTips } from "./handler.ts";

Deno.serve(handleGenerateParentTips);
