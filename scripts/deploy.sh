#!/usr/bin/env bash
# deploy.sh — interactive deploy for Supabase + Railway services
#
# Usage:
#   bash scripts/deploy.sh           # interactive picker
#   bash scripts/deploy.sh --all     # deploy everything non-interactively
#
# Requirements:
#   gum     (brew install gum)      — interactive picker
#   railway (brew install railway)  — Railway CLI  (run `railway login` first)
#   supabase CLI                    — wrapped via scripts/supabase.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPABASE="$ROOT_DIR/scripts/supabase.sh"

# ── colours ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "${GREEN}✓${NC} $*"; }
info() { echo -e "${CYAN}→${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BOLD}$*${NC}"; }

# ── Supabase project ref ──────────────────────────────────────────────────────
SUPABASE_PROJECT_REF_FILE="$ROOT_DIR/supabase/.temp/project-ref"
if [ -f "$SUPABASE_PROJECT_REF_FILE" ]; then
  SUPABASE_PROJECT_REF="$(cat "$SUPABASE_PROJECT_REF_FILE")"
else
  SUPABASE_PROJECT_REF="${SUPABASE_PROJECT_REF:-}"
fi

# ── preflight checks ──────────────────────────────────────────────────────────
if ! command -v gum &>/dev/null; then
  fail "gum is required for the interactive picker: brew install gum"
fi

if ! command -v railway &>/dev/null; then
  warn "railway CLI not found — Railway targets will be skipped (brew install railway)"
  RAILWAY_AVAILABLE=false
else
  # Rely entirely on the Railway CLI session (~/.railway/config.json).
  # Run `railway login` once to authenticate; no token env var needed.
  if ! railway whoami &>/dev/null; then
    echo -e "${RED}✗${NC} Not logged in to Railway." >&2
    echo    "  Run: railway login" >&2
    RAILWAY_AVAILABLE=false
  else
    RAILWAY_AVAILABLE=true
  fi
fi

if [ -z "${SUPABASE_PROJECT_REF:-}" ]; then
  warn "Supabase project ref not found. Run: bash scripts/supabase.sh link --project-ref <ref>"
fi

# ── deployable targets ────────────────────────────────────────────────────────
#
# Format: "DISPLAY_NAME|TYPE|ARG"
#   TYPE = supabase_migrate | supabase_fn_all | supabase_fn | railway_all | railway
#   ARG  = function name  (supabase_fn)
#        = service name   (railway)
#        = ignored        (everything else)

ALL_TARGETS=(
  "── Supabase ──────────────────────────|separator|"
  "DB Migrations                         |supabase_migrate|"
  "fn: all functions                     |supabase_fn_all|"
  "fn: db-maintenance                    |supabase_fn|db-maintenance"
  "fn: log-cron-run                      |supabase_fn|log-cron-run"
  "fn: notify-email                      |supabase_fn|notify-email"
  "fn: process-source-queue              |supabase_fn|process-source-queue"
  "fn: process-tag-queue                 |supabase_fn|process-tag-queue"
  "fn: scrape-due-sources                |supabase_fn|scrape-due-sources"
  "fn: scrape-source                     |supabase_fn|scrape-source"
  "fn: share-og                          |supabase_fn|share-og"
  "fn: tag-event                         |supabase_fn|tag-event"
  "── Railway ───────────────────────────|separator|"
  "all apps                              |railway_all|"
  "web                                   |railway|web"
  "cron-scrape-sources                   |railway|cron-scrape-sources"
  "cron-db-maintenance                   |railway|cron-db-maintenance"
  "cron-tag-queue                        |railway|cron-tag-queue"
  "llm-proxy                             |railway|llm-proxy"
  "llm-ollama (qwen3:1.7b)               |railway|llm-ollama"
)

# Build display list (separators are not selectable)
DISPLAY_ITEMS=()
SELECTABLE_TARGETS=()
for entry in "${ALL_TARGETS[@]}"; do
  label="${entry%%|*}"
  rest="${entry#*|}"
  deploy_type="${rest%%|*}"
  if [ "$deploy_type" != "separator" ]; then
    DISPLAY_ITEMS+=("$label")
    SELECTABLE_TARGETS+=("$entry")
  fi
done

# ── --all flag: skip picker ───────────────────────────────────────────────────
if [ "${1:-}" = "--all" ]; then
  SELECTED_TARGETS=("${SELECTABLE_TARGETS[@]}")
else
  echo ""
  echo -e "${BOLD}family-events-ui — Deploy${NC}"
  echo "Use space to select, enter to confirm."
  echo ""

  mapfile -t CHOSEN < <(
    gum choose --no-limit \
      --header "Select targets to deploy:" \
      --selected.foreground="0" \
      --selected.background="2" \
      "${DISPLAY_ITEMS[@]}"
  )

  if [ ${#CHOSEN[@]} -eq 0 ]; then
    warn "Nothing selected. Exiting."
    exit 0
  fi

  SELECTED_TARGETS=()
  for chosen_label in "${CHOSEN[@]}"; do
    for entry in "${SELECTABLE_TARGETS[@]}"; do
      entry_label="${entry%%|*}"
      if [ "$(echo "$entry_label" | xargs)" = "$(echo "$chosen_label" | xargs)" ]; then
        SELECTED_TARGETS+=("$entry")
        break
      fi
    done
  done
fi

if [ ${#SELECTED_TARGETS[@]} -eq 0 ]; then
  warn "No valid targets resolved. Exiting."
  exit 0
fi

# ── deduplication ─────────────────────────────────────────────────────────────
HAS_FN_ALL=false
HAS_RAILWAY_ALL=false
for entry in "${SELECTED_TARGETS[@]}"; do
  deploy_type="${entry#*|}"; deploy_type="${deploy_type%%|*}"
  [ "$deploy_type" = "supabase_fn_all" ] && HAS_FN_ALL=true
  [ "$deploy_type" = "railway_all"     ] && HAS_RAILWAY_ALL=true
done

DEDUPED=()
for entry in "${SELECTED_TARGETS[@]}"; do
  deploy_type="${entry#*|}"; deploy_type="${deploy_type%%|*}"
  [ "$HAS_FN_ALL"      = "true" ] && [ "$deploy_type" = "supabase_fn" ] && continue
  [ "$HAS_RAILWAY_ALL" = "true" ] && [ "$deploy_type" = "railway"     ] && continue
  DEDUPED+=("$entry")
done
SELECTED_TARGETS=("${DEDUPED[@]}")

# ── deployment functions ──────────────────────────────────────────────────────

deploy_supabase_migrate() {
  step "Supabase — DB Migrations"
  info "Running: supabase db push --linked"
  bash "$SUPABASE" db push --linked
  ok "Migrations applied."
}

# Edge-function import map is auto-discovered from supabase/functions/deno.json
# by the CLI bundler. The legacy --import-map flag was removed in CLI 2.101+.

deploy_supabase_fn() {
  local fn_name="$1"
  step "Supabase — function: $fn_name"
  if [ -z "${SUPABASE_PROJECT_REF:-}" ]; then
    fail "SUPABASE_PROJECT_REF not set. Run: bash scripts/supabase.sh link --project-ref <ref>"
  fi
  info "Running: supabase functions deploy $fn_name --project-ref $SUPABASE_PROJECT_REF"
  if ! bash "$SUPABASE" functions deploy "$fn_name" \
        --project-ref "$SUPABASE_PROJECT_REF"; then
    warn "Function '$fn_name' deploy FAILED."
    return 1
  fi
  ok "Function '$fn_name' deployed."
}

deploy_supabase_fn_all() {
  local functions=(
    db-maintenance
    log-cron-run
    notify-email
    process-source-queue
    process-tag-queue
    scrape-due-sources
    scrape-source
    share-og
    tag-event
  )
  step "Supabase — all edge functions"
  if [ -z "${SUPABASE_PROJECT_REF:-}" ]; then
    fail "SUPABASE_PROJECT_REF not set. Run: bash scripts/supabase.sh link --project-ref <ref>"
  fi
  local failed=()
  for fn_name in "${functions[@]}"; do
    info "Deploying: $fn_name"
    if bash "$SUPABASE" functions deploy "$fn_name" \
        --project-ref "$SUPABASE_PROJECT_REF"; then
      ok "$fn_name deployed."
    else
      warn "$fn_name deploy FAILED."
      failed+=("$fn_name")
    fi
  done
  if [ ${#failed[@]} -gt 0 ]; then
    warn "Failed functions: ${failed[*]}"
    return 1
  fi
}

# Maps Railway service name → local app subdirectory (relative to apps/).
# "web" is special-cased to ROOT_DIR. Add entries here when Railway renames a service.
railway_service_dir() {
  local service="$1"
  case "$service" in
    web)                      echo "" ;;          # ROOT_DIR
    cron-scrape-sources) echo "cron-scrape-sources" ;;
    cron-db-maintenance)      echo "cron-db-maintenance" ;;
    cron-tag-queue)      echo "cron-tag-queue" ;;
    llm-proxy)                echo "llm-proxy" ;;
    llm-ollama)               echo "qwen-ollama" ;;
    *)                        echo "$service" ;;  # fallback: same name
  esac
}

deploy_railway() {
  local service="$1"

  if [ "$RAILWAY_AVAILABLE" = "false" ]; then
    warn "Skipping Railway service '$service' — not logged in. Run: railway login"
    return 1
  fi

  step "Railway — service: $service"

  local subdir
  subdir="$(railway_service_dir "$service")"

  if [ -n "$subdir" ] && [ ! -d "$ROOT_DIR/apps/$subdir" ]; then
    warn "Directory not found: $ROOT_DIR/apps/$subdir — skipping '$service'."
    return 1
  fi

  info "Deploying from: $ROOT_DIR (Railway resolves rootDirectory from service config)"
  info "Running: railway up --service $service --detach"

  (cd "$ROOT_DIR" && railway up --service "$service" --detach) \
    || { warn "railway up failed for '$service'"; return 1; }

  ok "Railway deploy triggered for '$service'."
}

deploy_railway_all() {
  # Use the real Railway service names here
  local services=(web cron-scrape-sources cron-db-maintenance cron-tag-queue llm-proxy llm-ollama)
  step "Railway — all apps"
  for service in "${services[@]}"; do
    deploy_railway "$service" || { warn "Railway deploy failed: $service"; ERRORS=$((ERRORS + 1)); }
  done
}

# ── execute ───────────────────────────────────────────────────────────────────
ERRORS=0

echo ""
echo -e "${BOLD}Deploying ${#SELECTED_TARGETS[@]} target(s)...${NC}"

for entry in "${SELECTED_TARGETS[@]}"; do
  rest="${entry#*|}"
  deploy_type="${rest%%|*}"
  arg="${rest#*|}"

  case "$deploy_type" in
    supabase_migrate)
      deploy_supabase_migrate || { warn "Migrations failed."; ERRORS=$((ERRORS + 1)); }
      ;;
    supabase_fn_all)
      deploy_supabase_fn_all || { warn "Deploy all functions failed."; ERRORS=$((ERRORS + 1)); }
      ;;
    supabase_fn)
      deploy_supabase_fn "$arg" || { warn "Function deploy failed: $arg"; ERRORS=$((ERRORS + 1)); }
      ;;
    railway_all)
      deploy_railway_all || true  # inner loop tracks per-service errors
      ;;
    railway)
      deploy_railway "$arg" || { warn "Railway deploy failed: $arg"; ERRORS=$((ERRORS + 1)); }
      ;;
  esac
done

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────"
if [ "$ERRORS" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}Deploy complete!${NC} All targets succeeded."
else
  echo -e "${YELLOW}${BOLD}Deploy finished with $ERRORS error(s).${NC} Check output above."
  exit 1
fi
