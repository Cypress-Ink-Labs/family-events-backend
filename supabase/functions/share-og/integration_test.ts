import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert";
import { handleShareOg } from "./index.ts";

// Integration smoke test for the share-og edge function.
//
// Purpose: prove that a social-crawler request (Facebookbot-style User-Agent,
// valid UUID in the query) is served as server-rendered Open Graph HTML, not
// the SPA fallback. This is the surface that gets eyeballs in chat previews,
// so it must be 200 + contain real <meta property="og:..."> tags even when
// the underlying event lookup falls back (no DB env in the test process).
//
// Companion fix: `supabase/config.toml` flips `[functions.share-og]
// verify_jwt = false` so the Supabase gateway lets these unauthenticated
// crawler requests reach the function body at all.

const VALID_UUID = "11111111-2222-4333-8444-555555555555";

const CRAWLER_USER_AGENTS = [
  "facebookexternalhit/1.1",
  "Twitterbot/1.0",
  "LinkedInBot/1.0 (compatible; Mozilla/5.0; Jakarta Commons-HttpClient/3.1 +http://www.linkedin.com)",
  "Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)",
  "Mozilla/5.0 (compatible; Discordbot/2.0; +https://discordapp.com)",
];

if (typeof Deno !== "undefined") {
  Deno.test(
    "handleShareOg serves OG HTML to facebookexternalhit crawler",
    async () => {
      const response = await handleShareOg(
        new Request(
          `https://app.example.com/functions/v1/share-og?eventId=${VALID_UUID}`,
          {
            method: "GET",
            headers: { "User-Agent": "facebookexternalhit/1.1" },
          },
        ),
      );

      assertEquals(response.status, 200);
      assertStringIncludes(
        response.headers.get("Content-Type") ?? "",
        "text/html",
      );

      const body = await response.text();
      // Must be server-rendered OG, not the SPA shell.
      assertStringIncludes(body, '<meta property="og:title"');
      assertStringIncludes(body, '<meta property="og:description"');
      assertStringIncludes(body, '<meta property="og:image"');
      assertStringIncludes(body, '<meta property="og:url"');
      // og:url must echo the human-facing /share/<id> path, not the functions URL.
      assertStringIncludes(body, `/share/${VALID_UUID}`);
    },
  );

  Deno.test(
    "handleShareOg serves OG HTML to all known social-crawler UAs",
    async () => {
      for (const ua of CRAWLER_USER_AGENTS) {
        const response = await handleShareOg(
          new Request(
            `https://app.example.com/functions/v1/share-og?eventId=${VALID_UUID}`,
            { method: "GET", headers: { "User-Agent": ua } },
          ),
        );

        assertEquals(
          response.status,
          200,
          `crawler "${ua}" did not get 200`,
        );
        const body = await response.text();
        assertStringIncludes(
          body,
          '<meta property="og:title"',
          `crawler "${ua}" did not receive OG metadata`,
        );
      }
    },
  );

  Deno.test(
    "handleShareOg sets a public CDN-cache header so edge nodes can hold the preview",
    async () => {
      const response = await handleShareOg(
        new Request(
          `https://app.example.com/functions/v1/share-og?eventId=${VALID_UUID}`,
          {
            method: "GET",
            headers: { "User-Agent": "facebookexternalhit/1.1" },
          },
        ),
      );

      const cacheControl = response.headers.get("Cache-Control") ?? "";
      assert(
        cacheControl.includes("public"),
        `expected public Cache-Control, got "${cacheControl}"`,
      );
      assert(
        cacheControl.includes("s-maxage="),
        `expected s-maxage directive, got "${cacheControl}"`,
      );
    },
  );
}
