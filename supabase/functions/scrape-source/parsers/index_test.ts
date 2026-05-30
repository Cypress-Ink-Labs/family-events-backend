import { assertEquals } from "jsr:@std/assert"
import { parsers } from "./index.ts"

// Keep this list in lockstep with the consolidated event_sources.source_type
// CHECK constraint. If you add a parser, update both the schema baseline and
// this test so the TS-side registry and DB-side CHECK cannot silently drift.
const DB_ALLOWED_SOURCE_TYPES = [
  "brec",
  "downtownlafayette",
  "ical",
  "lcglafayette",
  "localhop",
  "macaronikid",
  "manual",
  "rss",
  "website",
]

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
