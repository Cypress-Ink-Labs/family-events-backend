import { assertEquals } from "jsr:@std/assert";
import { runParentTipsPass } from "./parent-tips-pass.ts";

class FakeSupabase {
  featureEnabled = true;
  claims = [{ event_id: "event-1" }];
  marked: string[] = [];
  calls: string[] = [];
  logged: Record<string, unknown>[] = [];

  from(table: string) {
    const self = this;
    return {
      select() {
        return this;
      },
      eq() {
        return this;
      },
      maybeSingle() {
        if (table !== "ai_feature_config") throw new Error(table);
        return Promise.resolve({
          data: { enabled: self.featureEnabled },
          error: null,
        });
      },
    };
  }

  rpc(name: string, args?: Record<string, unknown>) {
    this.calls.push(name);
    if (name === "list_events_needing_parent_tips") {
      return Promise.resolve({
        data: this.claims,
        error: null,
      });
    }
    if (name === "mark_event_enrichment_attempt") {
      this.marked.push(String(args?.p_event_id));
      return Promise.resolve({ data: null, error: null });
    }
    if (name === "log_cron_run_event") {
      this.logged.push(args ?? {});
      return Promise.resolve({ data: null, error: null });
    }
    return Promise.resolve({ data: null, error: null });
  }
}

async function withFetch(
  fetchImpl: typeof fetch,
  fn: () => Promise<void>,
): Promise<void> {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = fetchImpl;
  try {
    await fn();
  } finally {
    globalThis.fetch = originalFetch;
  }
}

Deno.test("runParentTipsPass skips disabled feature", async () => {
  const supabase = new FakeSupabase();
  supabase.featureEnabled = false;
  const summary = await runParentTipsPass({
    cronContext: { label: null, runKey: null },
    serviceRoleKey: "service",
    supabase: supabase as never,
    supabaseUrl: "https://project.supabase.co",
  });
  assertEquals(summary, {
    claimed: 0,
    enabled: false,
    errors: 0,
    generated: 0,
  });
});

Deno.test("runParentTipsPass invokes generate-parent-tips", async () => {
  let invokedUrl = "";
  await withFetch(
    (async (input) => {
      invokedUrl = String(input);
      return Response.json({ ok: true });
    }) as typeof fetch,
    async () => {
      const supabase = new FakeSupabase();
      const summary = await runParentTipsPass({
        cronContext: { label: null, runKey: null },
        serviceRoleKey: "service",
        supabase: supabase as never,
        supabaseUrl: "https://project.supabase.co",
      });
      assertEquals(
        invokedUrl,
        "https://project.supabase.co/functions/v1/generate-parent-tips",
      );
      assertEquals(summary.generated, 1);
    },
  );
});

Deno.test("runParentTipsPass stops on 503 without marking attempt", async () => {
  await withFetch(
    (async () => new Response("disabled", { status: 503 })) as typeof fetch,
    async () => {
      const supabase = new FakeSupabase();
      const summary = await runParentTipsPass({
        cronContext: { label: null, runKey: null },
        serviceRoleKey: "service",
        supabase: supabase as never,
        supabaseUrl: "https://project.supabase.co",
      });
      assertEquals(summary.errors, 1);
      assertEquals(summary.generated, 0);
      assertEquals(supabase.marked, []);
    },
  );
});

Deno.test("runParentTipsPass marks non-503 failures and continues", async () => {
  let callCount = 0;
  await withFetch(
    (async () => {
      callCount += 1;
      return callCount === 1
        ? new Response("bad", { status: 500 })
        : Response.json({ ok: true });
    }) as typeof fetch,
    async () => {
      const supabase = new FakeSupabase();
      supabase.claims = [{ event_id: "event-1" }, { event_id: "event-2" }];
      const summary = await runParentTipsPass({
        cronContext: { label: null, runKey: null },
        serviceRoleKey: "service",
        supabase: supabase as never,
        supabaseUrl: "https://project.supabase.co",
      });
      assertEquals(summary.errors, 1);
      assertEquals(summary.generated, 1);
      assertEquals(supabase.marked, ["event-1"]);
    },
  );
});

Deno.test("runParentTipsPass logs invocation exceptions", async () => {
  await withFetch(
    (async () => {
      throw new Error("network timeout");
    }) as typeof fetch,
    async () => {
      const supabase = new FakeSupabase();
      const summary = await runParentTipsPass({
        cronContext: {
          label: "cron-enrich-events",
          runKey: "11111111-2222-3333-4444-555555555555",
        },
        serviceRoleKey: "service",
        supabase: supabase as never,
        supabaseUrl: "https://project.supabase.co",
      });
      assertEquals(summary.errors, 1);
      assertEquals(summary.generated, 0);
      assertEquals(supabase.logged.length, 1);
      assertEquals(supabase.logged[0].p_message, "parent-tips row failed");
    },
  );
});
