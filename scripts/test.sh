#!/usr/bin/env bash
# Run Supabase SQL integration tests (RLS, RPC, pagination, etc.).
#
# Usage:
#   bash scripts/test.sh                         # local supabase must be running
#   bash scripts/test.sh "$DB_URL"               # explicit connection string
#   DB_URL=postgresql://... bash scripts/test.sh # via env (CI)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
Usage: bash scripts/test.sh [DB_URL]

Runs supabase/tests/*.sql against the target Postgres database.

DB_URL resolution (first match wins):
  1. First positional argument
  2. DB_URL environment variable
  3. `supabase status --output env` (local dev)

Requires: psql
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -n "${1:-}" ]]; then
  DB_URL="$1"
elif [[ -n "${DB_URL:-}" ]]; then
  :
else
  SUPABASE_CLI="$ROOT_DIR/scripts/supabase.sh"
  STATUS=$(bash "$SUPABASE_CLI" status --output env 2>/dev/null) || {
    echo "error: supabase is not running and no DB_URL was provided." >&2
    echo "Start local stack: pnpm run db:start" >&2
    usage >&2
    exit 1
  }
  DB_URL=$(echo "$STATUS" | grep '^DB_URL=' | cut -d'"' -f2)
  [[ -n "$DB_URL" ]] || {
    echo "error: could not read DB_URL from supabase status" >&2
    exit 1
  }
fi

command -v psql >/dev/null 2>&1 || {
  echo "error: psql not found (install postgresql-client)" >&2
  exit 1
}

TEST_FILES=(
  supabase/tests/rls_anon_read.sql
  supabase/tests/rls_public_events_view.sql
  supabase/tests/rls_access_expiry.sql
  supabase/tests/rls_privilege_escalation.sql
  supabase/tests/cron_rpc_security.sql
  supabase/tests/cron_toggle.sql
  supabase/tests/search_events_full_text.sql
  supabase/tests/events_cursor_pagination.sql
  supabase/tests/admin_events_rpc.sql
  supabase/tests/role_smoke.sql
  supabase/tests/admin_db_health.sql
  supabase/tests/trace_retention.sql
  supabase/tests/api_surface_hardening.sql
  supabase/tests/events_enriched_parity.sql
  supabase/tests/reference_data.sql
)

for test_file in "${TEST_FILES[@]}"; do
  echo "→ $test_file"
  psql "$DB_URL" -v ON_ERROR_STOP=1 -f "$test_file"
done

echo "All ${#TEST_FILES[@]} database tests passed."
