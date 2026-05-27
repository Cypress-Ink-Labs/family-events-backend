import { defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    include: ["_shared/**/*.test.ts"],
    environment: "node",
  },
})
