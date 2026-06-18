import { assertEquals, assertRejects } from "jsr:@std/assert";
import { enqueueSourceScrape } from "./source-queue.ts";

type RpcResponse = {
  data: unknown;
  error: Error | null;
};

class FakeSupabaseClient {
  calls: Array<{ name: string; params: Record<string, unknown> }> = [];

  constructor(private readonly response: RpcResponse) {}

  rpc(name: string, params: Record<string, unknown>) {
    this.calls.push({ name, params });
    return {
      maybeSingle: () => Promise.resolve(this.response),
    };
  }
}

Deno.test("enqueueSourceScrape uses the atomic enqueue RPC", async () => {
  const supabase = new FakeSupabaseClient({
    data: { queue_id: 42, deduped: false },
    error: null,
  });

  const result = await enqueueSourceScrape(
    supabase as never,
    "16130a33-6740-4110-8465-f767630f6d2e",
    "scheduled",
  );

  assertEquals(result, { queue_id: 42, deduped: false });
  assertEquals(supabase.calls, [
    {
      name: "enqueue_source_scrape",
      params: {
        p_source_id: "16130a33-6740-4110-8465-f767630f6d2e",
        p_trigger_type: "scheduled",
      },
    },
  ]);
});

Deno.test("enqueueSourceScrape returns existing queue rows as deduped", async () => {
  const supabase = new FakeSupabaseClient({
    data: { queue_id: 7, deduped: true },
    error: null,
  });

  const result = await enqueueSourceScrape(
    supabase as never,
    "16130a33-6740-4110-8465-f767630f6d2e",
  );

  assertEquals(result, { queue_id: 7, deduped: true });
});

Deno.test("enqueueSourceScrape throws RPC errors", async () => {
  const supabase = new FakeSupabaseClient({
    data: null,
    error: new Error("rpc failed"),
  });

  await assertRejects(
    () => enqueueSourceScrape(supabase as never, "16130a33-6740-4110-8465-f767630f6d2e"),
    Error,
    "rpc failed",
  );
});
