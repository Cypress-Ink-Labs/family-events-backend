import { defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    // vitest covers the pure-logic _shared/*.test.ts modules (node env). Edge-function
    // handler tests use Deno.test() + jsr: imports and live in their function dirs — those
    // run under `deno test` (see the `test:deno` script), NOT vitest. Keep this scoped to
    // _shared so a Deno-style `*.test.ts` in a function dir is never picked up here.
    include: ["_shared/**/*.test.ts"],
    exclude: ["node_modules/**"],
    environment: "node",
    includeTaskLocation: true,
  },
})
