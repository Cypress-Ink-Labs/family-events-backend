#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_CLI="$ROOT_DIR/node_modules/supabase/bin/supabase"

if SYSTEM_CLI="$(command -v supabase 2>/dev/null)" && [ -x "$SYSTEM_CLI" ]; then
  exec "$SYSTEM_CLI" "$@"
fi

if [ -x "$LOCAL_CLI" ]; then
  exec "$LOCAL_CLI" "$@"
fi

export npm_config_loglevel="${npm_config_loglevel:-silent}"
exec npx -y supabase@latest "$@"
