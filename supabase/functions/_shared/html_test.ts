import { assertEquals } from "jsr:@std/assert";
import { escapeHtml } from "./html.ts";

Deno.test("escapeHtml escapes HTML-sensitive characters", () => {
  assertEquals(
    escapeHtml(`&<>"'`),
    "&amp;&lt;&gt;&quot;&#39;",
  );
});
