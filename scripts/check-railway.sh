#!/usr/bin/env bash
# check-railway.sh — audit Railway services against repo state.
#
# Catches the bug class that's bitten this repo twice:
#   - Service created via `railway add --service <name>` (empty) gets
#     rootDirectory=NULL. railway up then builds the whole monorepo,
#     usually serving Vite static output instead of the actual app.
#   - cronSchedule drift between Railway-stored config and .railway/railway.ts.
#
# Usage:
#   bash scripts/check-railway.sh           # report only
#   bash scripts/check-railway.sh --fix     # apply rootDirectory + cronSchedule
#                                           # corrections via GraphQL
#
# Requires: jq, railway CLI logged in, ~/.railway/config.json present.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ID="b97c92f7-464e-4f77-a760-725fc9fdb5a2"
ENV_ID="03e869e2-4e35-4849-84b7-6c0278c1c6fb"
FIX=false
[ "${1:-}" = "--fix" ] && FIX=true

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

TOKEN=$(jq -r '.user.accessToken' ~/.railway/config.json)
if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo -e "${RED}✗${NC} No Railway access token in ~/.railway/config.json. Run: railway login"
  exit 1
fi

IAC_JSON=$(pnpm exec railway-iac-ts "$ROOT_DIR/.railway/railway.ts")

graphql() {
  curl -s -X POST https://backboard.railway.com/graphql/v2 \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "{\"query\":$(jq -Rsc <<<"$1")}"
}

service_in_iac() {
  local name="$1"
  jq -e --arg name "$name" '.graph.resources[] | select(.type == "service" and .name == $name)' <<<"$IAC_JSON" >/dev/null
}

expected_root_for() {
  local name="$1"
  if ! service_in_iac "$name"; then
    echo "UNMANAGED"
    return
  fi
  jq -r --arg name "$name" '
    .graph.resources[]
    | select(.type == "service" and .name == $name)
    | .source.rootDirectory // "NULL"
  ' <<<"$IAC_JSON"
}

expected_cron_for() {
  local name="$1"
  if ! service_in_iac "$name"; then
    echo ""
    return
  fi
  jq -r --arg name "$name" '
    .graph.resources[]
    | select(.type == "service" and .name == $name)
    | .deploy.cronSchedule // ""
  ' <<<"$IAC_JSON"
}

echo -e "${CYAN}→${NC} Querying Railway project services..."
SERVICES_JSON=$(graphql "query { project(id: \"$PROJECT_ID\") { services { edges { node { id name } } } } }")
SERVICES=$(echo "$SERVICES_JSON" | jq -r '.data.project.services.edges[].node | "\(.id)|\(.name)"')

if [ -z "$SERVICES" ]; then
  echo -e "${RED}✗${NC} No services returned. Token scope or project id wrong."
  exit 1
fi

ISSUES=0
FIXED=0
printf "\n%-25s | %-30s | %-30s | %s\n" "SERVICE" "ROOT_DIR (got)" "ROOT_DIR (expected)" "STATUS"
printf -- '%.0s-' {1..120}; echo

while IFS='|' read -r SVC_ID NAME; do
  INSTANCE=$(graphql "query { serviceInstance(serviceId: \"$SVC_ID\", environmentId: \"$ENV_ID\") { rootDirectory cronSchedule } }")
  GOT_ROOT=$(echo "$INSTANCE" | jq -r '.data.serviceInstance.rootDirectory // "NULL"')
  GOT_CRON=$(echo "$INSTANCE" | jq -r '.data.serviceInstance.cronSchedule // ""')

  EXPECTED_ROOT=$(expected_root_for "$NAME")

  ROOT_OK=true
  if [ "$GOT_ROOT" != "$EXPECTED_ROOT" ]; then
    ROOT_OK=false
  fi

  EXPECTED_CRON=$(expected_cron_for "$NAME")
  CRON_OK=true
  if [ -n "$EXPECTED_CRON" ] && [ "$GOT_CRON" != "$EXPECTED_CRON" ]; then
    CRON_OK=false
  fi

  STATUS=""
  if $ROOT_OK && $CRON_OK; then
    STATUS="${GREEN}OK${NC}"
  elif ! $ROOT_OK && ! $CRON_OK; then
    STATUS="${RED}ROOT+CRON DRIFT${NC}"
    ISSUES=$((ISSUES + 1))
  elif ! $ROOT_OK; then
    STATUS="${RED}ROOT DRIFT${NC}"
    ISSUES=$((ISSUES + 1))
  else
    STATUS="${YELLOW}CRON DRIFT (iac=$EXPECTED_CRON)${NC}"
    ISSUES=$((ISSUES + 1))
  fi

  printf "%-25s | %-30s | %-30s | %b\n" "$NAME" "$GOT_ROOT" "$EXPECTED_ROOT" "$STATUS"

  if $FIX && ! $ROOT_OK && [ "$EXPECTED_ROOT" != "NULL" ] && [ "$EXPECTED_ROOT" != "UNMANAGED" ]; then
    RES=$(graphql "mutation { serviceInstanceUpdate(serviceId: \"$SVC_ID\", environmentId: \"$ENV_ID\", input: { rootDirectory: \"$EXPECTED_ROOT\" }) }")
    if echo "$RES" | jq -e '.data.serviceInstanceUpdate' >/dev/null 2>&1; then
      echo -e "  ${GREEN}✓${NC} fixed rootDirectory → $EXPECTED_ROOT"
      FIXED=$((FIXED + 1))
    else
      echo -e "  ${RED}✗${NC} fix failed: $(echo "$RES" | jq -c '.errors // .')"
    fi
  fi
  if $FIX && ! $CRON_OK; then
    RES=$(graphql "mutation { serviceInstanceUpdate(serviceId: \"$SVC_ID\", environmentId: \"$ENV_ID\", input: { cronSchedule: \"$EXPECTED_CRON\" }) }")
    if echo "$RES" | jq -e '.data.serviceInstanceUpdate' >/dev/null 2>&1; then
      echo -e "  ${GREEN}✓${NC} fixed cronSchedule → $EXPECTED_CRON"
      FIXED=$((FIXED + 1))
    else
      echo -e "  ${RED}✗${NC} fix failed: $(echo "$RES" | jq -c '.errors // .')"
    fi
  fi
done <<<"$SERVICES"

echo
if [ "$ISSUES" -eq 0 ]; then
  echo -e "${GREEN}✓${NC} All Railway services match repo state."
  exit 0
fi

if $FIX; then
  echo -e "${YELLOW}!${NC} Found $ISSUES issue(s), fixed $FIXED."
  echo -e "${CYAN}→${NC} Trigger redeploy(s) to pick up new rootDirectory:"
  echo "  railway up --service <name> --detach"
  exit 0
fi

echo -e "${RED}✗${NC} Found $ISSUES issue(s). Re-run with --fix to apply via Railway GraphQL."
exit 1
