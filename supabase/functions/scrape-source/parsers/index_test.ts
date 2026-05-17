import { assertEquals } from "jsr:@std/assert"
import { parsers } from "./index.ts"

// Keep this list in lockstep with the CHECK constraint in
// supabase/migrations/20260601002600_macaronikid_parser.sql. If you add a
// parser, update both. This test ensures TS-side registry and DB-side CHECK
// can never silently drift.
const DB_ALLOWED_SOURCE_TYPES = ["ical", "macaronikid", "manual", "rss", "website"]

if (typeof Deno !== "undefined") {
  Deno.test("parser registry keys match the DB CHECK constraint allowlist", () => {
    assertEquals(Object.keys(parsers).slice().sort(), DB_ALLOWED_SOURCE_TYPES.slice().sort())
  })

  Deno.test("each registered parser exposes the correct type tag", () => {
    for (const [key, parser] of Object.entries(parsers)) {
      assertEquals(parser.type, key)
    }
  })
}
