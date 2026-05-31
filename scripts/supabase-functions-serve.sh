#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FUNCTIONS_DIR="$ROOT_DIR/supabase/functions"

# Deno's nodeModulesDir output is generated and can leave broken symlinks after
# interrupted local serves. Supabase watches these directories, so stale trees
# can crash `functions serve` before the runtime starts.
find "$FUNCTIONS_DIR" -mindepth 1 -maxdepth 2 -type d -name node_modules -prune -exec rm -rf {} +

export SUPABASE_FUNCTIONS_WATCH_LIMIT="${SUPABASE_FUNCTIONS_WATCH_LIMIT:-4000}"

cd "$ROOT_DIR"
exec bash scripts/supabase.sh functions serve "$@"
