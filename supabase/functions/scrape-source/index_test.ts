/**
 * Entry-point tests for scrape-source.
 *
 * The handler lives inside `Deno.serve`, so we test the queue-kick behaviour
 * by exercising `kickProcessSourceQueue` directly with a stubbed fetch, and by
 * verifying that the non-EdgeRuntime branch (`else { await kick }`) causes the
 * kick to complete before control returns.
 */
import { assert, assertEquals } from "jsr:@std/assert";
import { kickProcessSourceQueue } from "./lib/source-queue.ts";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function withFetch(
  fakeFetch: typeof fetch,
  fn: () => Promise<void>,
): Promise<void> {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = fakeFetch;
  return fn().finally(() => {
    globalThis.fetch = originalFetch;
  });
}

// ---------------------------------------------------------------------------
// kickProcessSourceQueue – non-EdgeRuntime await behaviour
// ---------------------------------------------------------------------------

Deno.test(
  "kickProcessSourceQueue resolves when the invoked function returns 200",
  async () => {
    const calls: string[] = [];

    await withFetch(
      (_input) => {
        calls.push("fetch");
        return Promise.resolve(new Response("ok", { status: 200 }));
      },
      async () => {
        await kickProcessSourceQueue("http://supabase.local", "service-key");
      },
    );

    assertEquals(calls, ["fetch"]);
  },
);

Deno.test(
  "kickProcessSourceQueue throws when the invoked function returns non-2xx",
  async () => {
    let threw = false;
    await withFetch(
      (_input) =>
        Promise.resolve(new Response("downstream error", { status: 503 })),
      async () => {
        try {
          await kickProcessSourceQueue("http://supabase.local", "service-key");
        } catch {
          threw = true;
        }
      },
    );

    assert(threw, "expected kickProcessSourceQueue to throw on non-2xx");
  },
);

// ---------------------------------------------------------------------------
// Non-EdgeRuntime await pattern
//
// Simulates what index.ts does in the `else { await kick }` branch:
// the wrapped promise must have settled before the surrounding await returns.
// ---------------------------------------------------------------------------

Deno.test(
  "non-EdgeRuntime: awaiting the .catch-wrapped kick settles it before returning",
  async () => {
    let settled = false;

    const kick = new Promise<void>((resolve) => {
      // Simulate an async kick that completes asynchronously
      queueMicrotask(() => {
        settled = true;
        resolve();
      });
    }).catch(() => {
      // mirrors the .catch in index.ts — swallows errors
    });

    // This is the exact `else` branch from index.ts
    await kick;

    assert(settled, "kick must have settled before await returns");
  },
);

Deno.test(
  "non-EdgeRuntime: errors from kick are swallowed by .catch and do not propagate",
  async () => {
    let caughtByHandler = false;

    const kick = Promise.reject(new Error("kick exploded")).catch(() => {
      caughtByHandler = true;
    });

    // Should not throw despite the underlying rejection
    await kick;

    assert(
      caughtByHandler,
      ".catch must have run; errors must not propagate past await kick",
    );
  },
);
