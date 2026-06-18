# Forge Builder Memory

- [New edge function registration checklist](feedback_new-edge-function-registration.md) — 4-step process: create dir + index.ts + deno.json; update deploy.config.json; update config.toml; run both guard tests
- [Deno iCal CRLF test pattern](feedback_deno-ical-crlf-test.md) — use `/(?<!\r)\n/.test(ical)` not `ical.includes("\n")` to check for bare newlines
