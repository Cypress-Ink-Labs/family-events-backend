import { defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    include: ["**/*.test.ts"],
    // These files use Deno.test() + jsr: imports — they run under `deno test`, not vitest.
    // node_modules/.deno is Deno's local cache; it must be excluded too.
    exclude: [
      "node_modules/**",
      "send-push/send-push.test.ts",
      "send-reminders/send-reminders.test.ts",
      "send-weekly-digest/send-weekly-digest.test.ts",
    ],
    environment: "node",
    includeTaskLocation: true,
  },
})
