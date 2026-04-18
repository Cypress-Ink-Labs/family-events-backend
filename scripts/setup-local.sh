#!/usr/bin/env bash
# setup-local.sh — re-apply local dev settings after `supabase db reset`
#
# Run: npm run setup:local
#
# What this does:
#   1. Reads connection info from `supabase status`
#   2. Sets app.settings.* so scheduled scraping cron works
#   3. Sets admin email and promotes the local admin user
#   4. Verifies the setup completed

set -euo pipefail

# ── colours ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

echo ""
echo "family-events-ui — local dev setup"
echo "──────────────────────────────────"

# ── 1. Pull config from supabase status ──────────────────────────────────────
SUPABASE_CLI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/supabase.sh"
STATUS=$("$SUPABASE_CLI" status --output env 2>/dev/null) || fail "supabase is not running. Start it with: npm run supabase:start"

SERVICE_ROLE_KEY=$(echo "$STATUS" | grep '^SERVICE_ROLE_KEY=' | cut -d'"' -f2)
DB_URL=$(echo "$STATUS"           | grep '^DB_URL='          | cut -d'"' -f2)
API_URL=$(echo "$STATUS"          | grep '^API_URL='         | cut -d'"' -f2)

[ -z "$SERVICE_ROLE_KEY" ] && fail "Could not read SERVICE_ROLE_KEY from supabase status"
[ -z "$DB_URL"           ] && fail "Could not read DB_URL from supabase status"

# pg_net calls come from inside Docker, so swap 127.0.0.1 → host.docker.internal
INTERNAL_URL="${API_URL/127.0.0.1/host.docker.internal}"

ADMIN_PG_URL="${DB_URL/postgres:postgres/supabase_admin:postgres}"

# ── 2. Set app.settings for scheduled scraping ───────────────────────────────
echo ""
echo "Step 1/3 — Configuring scheduled scraping settings"

psql "$ADMIN_PG_URL" -q \
  -c "ALTER DATABASE postgres SET \"app.settings.supabase_url\" = '${INTERNAL_URL}';" \
  -c "ALTER DATABASE postgres SET \"app.settings.service_role_key\" = '${SERVICE_ROLE_KEY}';" \
  2>/dev/null || fail "Failed to set app.settings (check supabase_admin credentials)"

ok "app.settings.supabase_url  = $INTERNAL_URL"
ok "app.settings.service_role_key set"

# Invite gate: default off locally. Flip with REQUIRE_INVITE=true npm run setup:local
REQUIRE_INVITE="${REQUIRE_INVITE:-false}"
psql "$ADMIN_PG_URL" -q \
  -c "ALTER DATABASE postgres SET \"app.settings.require_invite\" = '${REQUIRE_INVITE}';" \
  2>/dev/null
ok "app.settings.require_invite = $REQUIRE_INVITE"

# ── 3. Set admin email and bootstrap ─────────────────────────────────────────
echo ""
echo "Step 2/3 — Bootstrapping admin user"

ADMIN_EMAIL="admin@familyevents.local"

psql "$ADMIN_PG_URL" -q \
  -c "ALTER DATABASE postgres SET \"app.settings.admin_email\" = '${ADMIN_EMAIL}';" \
  2>/dev/null

RESULT=$(psql "$DB_URL" -t -q \
  -c "SELECT private.bootstrap_admin();" 2>/dev/null | xargs)

ROLE=$(psql "$DB_URL" -t -q \
  -c "SELECT role FROM user_profiles WHERE email = '${ADMIN_EMAIL}';" 2>/dev/null | xargs)

if [ "$ROLE" = "admin" ]; then
  ok "Admin user: $ADMIN_EMAIL (role=admin)"
else
  warn "Admin profile not found yet — sign up at /sign-up with $ADMIN_EMAIL, then re-run this script"
fi

# ── 4. Verify ─────────────────────────────────────────────────────────────────
echo ""
echo "Step 3/3 — Verifying"

SOURCES=$(psql "$DB_URL" -t -q \
  -c "SELECT COUNT(*) FROM event_sources WHERE is_active = true;" 2>/dev/null | xargs)

ok "Active event sources: $SOURCES"

echo ""
echo "──────────────────────────────────"
echo -e "${GREEN}Local setup complete!${NC}"
echo ""
echo "  Admin login:  $ADMIN_EMAIL / Admin123!"
echo "  Studio:       http://127.0.0.1:55323"
echo "  App:          http://localhost:5173"
echo ""
