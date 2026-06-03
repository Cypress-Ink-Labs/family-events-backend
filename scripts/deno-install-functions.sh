#!/usr/bin/env bash
#
# Install Deno dependencies (and generate/update deno.lock) for every
# Supabase Edge Function that has its own deno.json.
#
# Usage:
#   pnpm deno:install
#   # or directly:
#   bash scripts/deno-install-functions.sh
#
set -euo pipefail

echo "🔧 Installing Deno deps for Supabase Edge Functions..."

count=0

for dir in supabase/functions/*/; do
  if [ -f "${dir}deno.json" ] && [ -f "${dir}index.ts" ]; then
    name=$(basename "$dir")
    echo "  → $name"
    (cd "$dir" && deno install)
    count=$((count + 1))
  fi
done

if [ "$count" -eq 0 ]; then
  echo "No functions with deno.json + index.ts found."
else
  echo "✅ Done. Updated $count function(s)."
fi
