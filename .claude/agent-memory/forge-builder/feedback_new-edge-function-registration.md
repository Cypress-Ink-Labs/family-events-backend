---
name: new-edge-function-registration
description: 4-step checklist for registering a new Supabase edge function in this repo
metadata:
  type: feedback
---

When adding a new public edge function, all 4 steps are required or guard tests fail:

1. Create `supabase/functions/<name>/index.ts` AND `supabase/functions/<name>/deno.json` (copy shape from sitemap/deno.json — just imports block, no test config needed).
2. Add `<name>` to `config/deploy.config.json` `supabase.functions` array (alphabetical order) AND to `supabase.noVerifyJwtFunctions` if public.
3. Add `[functions.<name>]` block with `verify_jwt = false` to `supabase/config.toml` (model on sitemap/share-og blocks with a comment explaining why it's public).
4. Verify: `node --test tests/guards/deploy-cli-boundary.test.mjs` AND `node --test tests/guards/supabase-function-auth-config.test.mjs` both pass.

**Why:** deploy-cli guard scans for dirs with index.ts and checks they're all in deploy.config.json; auth-config guard cross-checks noVerifyJwtFunctions against config.toml blocks.

**How to apply:** Any time a new function directory with index.ts is created.
