#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_CLI="$ROOT_DIR/node_modules/supabase/bin/supabase"
PINNED_VERSION="2.109.0"

if SYSTEM_CLI="$(command -v supabase 2>/dev/null)" && [ -x "$SYSTEM_CLI" ]; then
  exec "$SYSTEM_CLI" "$@"
fi

if [ -x "$LOCAL_CLI" ]; then
  exec "$LOCAL_CLI" "$@"
fi

# Last resort: pinned, not "@latest" — every other path in this repo (CI,
# deploy) installs this exact version via supabase/setup-cli@v1, so an
# unpinned npx fallback would be the one place version drift could sneak in.
export npm_config_loglevel="${npm_config_loglevel:-silent}"
exec npx -y "supabase@$PINNED_VERSION" "$@"
