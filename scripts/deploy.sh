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
DEPLOY_ALL=false
if [ "${1:-}" = "--all" ]; then
  DEPLOY_ALL=true
fi

if [ -f "$SUPABASE_PROJECT_REF_FILE" ]; then
  SUPABASE_PROJECT_REF="$(cat "$SUPABASE_PROJECT_REF_FILE")"
else
  SUPABASE_PROJECT_REF="${SUPABASE_PROJECT_REF:-}"
fi

# ── preflight checks ──────────────────────────────────────────────────────────
if [ "$DEPLOY_ALL" = "false" ] && ! command -v gum &>/dev/null; then
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
  "fn: backfill-event-enrichment         |supabase_fn|backfill-event-enrichment"
  "fn: cleanup-stale-runs                |supabase_fn|cleanup-stale-runs"
  "fn: db-maintenance                    |supabase_fn|db-maintenance"
  "fn: log-cron-run                      |supabase_fn|log-cron-run"
  "fn: notify-email                      |supabase_fn|notify-email"
  "fn: process-source-queue              |supabase_fn|process-source-queue"
  "fn: process-event-review-queue        |supabase_fn|process-event-review-queue"
  "fn: process-tag-queue                 |supabase_fn|process-tag-queue"
  "fn: scrape-due-sources                |supabase_fn|scrape-due-sources"
  "fn: scrape-source                     |supabase_fn|scrape-source"
  "fn: send-auth-email                   |supabase_fn|send-auth-email"
  "fn: share-og                          |supabase_fn|share-og"
  "fn: tag-event                         |supabase_fn|tag-event"
  "── Railway ───────────────────────────|separator|"
  "all apps                              |railway_all|"
  "web                                   |railway|web"
  "cron-scrape-sources                   |railway|cron-scrape-sources"
  "cron-db-maintenance                   |railway|cron-db-maintenance"
  "cron-tag-queue                        |railway|cron-tag-queue"
  "cron-enrich-events                    |railway|cron-enrich-events"
  "cron-review-events                    |railway|cron-review-events"
  "cron-cleanup-stale                    |railway|cron-cleanup-stale"
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
if [ "$DEPLOY_ALL" = "true" ]; then
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
  info "Preflight: supabase migration list --linked"
  bash "$SUPABASE" migration list --linked || warn "Could not read linked migration list."
  info "Preflight: supabase db lint --linked"
  bash "$SUPABASE" db lint --linked || warn "Supabase db lint failed or is unavailable for this environment."
  info "Preflight: supabase db push --linked --dry-run"
  bash "$SUPABASE" db push --linked --dry-run || warn "Supabase db push dry-run failed or is unavailable; continuing with explicit db push."
  info "Running: supabase db push --linked"
  bash "$SUPABASE" db push --linked
  ok "Migrations applied."
}

# Edge-function import map is auto-discovered from supabase/functions/deno.json
# by the CLI bundler. The legacy --import-map flag was removed in CLI 2.101+.

# Edge functions that accept the Supabase service-role key (`sb_secret_*`,
# opaque non-JWT) need verify_jwt=false because the platform gateway rejects
# anything that isn't a parseable JWT BEFORE the function body runs. Each
# function still authenticates via `requireServiceRole` in its body. Listed
# explicitly so a new function gets the safe default (verify_jwt=true) unless
# we opt in here. Only share-og — the public OG image endpoint — is intentionally
# left with verify_jwt=true.
NO_VERIFY_JWT_FUNCTIONS=(
  backfill-event-enrichment
  cleanup-stale-runs
  db-maintenance
  log-cron-run
  notify-email
  process-source-queue
  process-event-review-queue
  process-tag-queue
  scrape-due-sources
  scrape-source
  send-auth-email
  tag-event
)

deploy_supabase_fn() {
  local fn_name="$1"
  step "Supabase — function: $fn_name"
  if [ -z "${SUPABASE_PROJECT_REF:-}" ]; then
    fail "SUPABASE_PROJECT_REF not set. Run: bash scripts/supabase.sh link --project-ref <ref>"
  fi

  local extra_args=()
  for skip_jwt_fn in "${NO_VERIFY_JWT_FUNCTIONS[@]}"; do
    if [ "$skip_jwt_fn" = "$fn_name" ]; then
      extra_args+=("--no-verify-jwt")
      break
    fi
  done

  info "Running: supabase functions deploy $fn_name --project-ref $SUPABASE_PROJECT_REF ${extra_args[*]}"
  if ! bash "$SUPABASE" functions deploy "$fn_name" \
        --project-ref "$SUPABASE_PROJECT_REF" \
        "${extra_args[@]}"; then
    warn "Function '$fn_name' deploy FAILED."
    return 1
  fi
  ok "Function '$fn_name' deployed."
}

deploy_supabase_fn_all() {
  local functions=(
    backfill-event-enrichment
    cleanup-stale-runs
    db-maintenance
    log-cron-run
    notify-email
    process-source-queue
    process-event-review-queue
    process-tag-queue
    scrape-due-sources
    scrape-source
    send-auth-email
    share-og
    tag-event
  )
  step "Supabase — all edge functions"
  if [ -z "${SUPABASE_PROJECT_REF:-}" ]; then
    fail "SUPABASE_PROJECT_REF not set. Run: bash scripts/supabase.sh link --project-ref <ref>"
  fi
  local discovered=()
  mapfile -t discovered < <(
    find "$ROOT_DIR/supabase/functions" -mindepth 1 -maxdepth 1 -type d \
      -not -name '_shared' \
      -not -name 'node_modules' \
      -exec sh -c '[ -f "$1/index.ts" ] && basename "$1"' sh {} \; | sort
  )
  local expected_sorted=()
  mapfile -t expected_sorted < <(printf '%s\n' "${functions[@]}" | sort)
  if [ "$(printf '%s\n' "${discovered[@]}")" != "$(printf '%s\n' "${expected_sorted[@]}")" ]; then
    warn "Function deploy list does not match supabase/functions directories."
    warn "Expected: ${expected_sorted[*]}"
    warn "Found: ${discovered[*]}"
    return 1
  fi
  local failed=()
  local first_function=true
  for fn_name in "${functions[@]}"; do
    if [ "$first_function" = "true" ]; then
      first_function=false
    else
      echo ""
    fi

    local extra_args=()
    for skip_jwt_fn in "${NO_VERIFY_JWT_FUNCTIONS[@]}"; do
      if [ "$skip_jwt_fn" = "$fn_name" ]; then
        extra_args+=("--no-verify-jwt")
        break
      fi
    done

    info "Deploying: $fn_name"
    if bash "$SUPABASE" functions deploy "$fn_name" \
        --project-ref "$SUPABASE_PROJECT_REF" \
        "${extra_args[@]}"; then
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

railway_service_exists() {
  local service="$1"
  railway service list --json 2>/dev/null \
    | jq -e --arg service "$service" '.[] | select(.name == $service)' >/dev/null 2>&1
}

bootstrap_created_railway_service() {
  local service="$1"

  case "$service" in
    cron-review-events)
      local source_vars process_url
      source_vars="$(railway variable list --service cron-enrich-events --json 2>/dev/null || true)"
      if [ -z "$source_vars" ]; then
        warn "Could not read cron-enrich-events variables to bootstrap '$service'."
        return 0
      fi

      for key in SUPABASE_SERVICE_ROLE_KEY IS_CRON_ENABLED_URL LOG_CRON_RUN_URL; do
        local value
        value="$(printf '%s' "$source_vars" | jq -r --arg key "$key" '.[$key] // empty' 2>/dev/null || true)"
        if [ -n "$value" ]; then
          railway variable set --service "$service" --skip-deploys --json "$key=$value" >/dev/null
        fi
      done

      process_url="$(
        printf '%s' "$source_vars" \
          | jq -r '.BACKFILL_EVENT_ENRICHMENT_URL // empty' 2>/dev/null \
          | sed 's#/functions/v1/backfill-event-enrichment$#/functions/v1/process-event-review-queue#'
      )"
      if [ -n "$process_url" ]; then
        railway variable set --service "$service" --skip-deploys --json \
          "PROCESS_EVENT_REVIEW_QUEUE_URL=$process_url" >/dev/null
      else
        warn "Could not derive PROCESS_EVENT_REVIEW_QUEUE_URL for '$service'."
      fi
      ;;
  esac
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
    cron-review-events)  echo "cron-review-events" ;;
    cron-cleanup-stale)  echo "cron-cleanup-stale" ;;
    *)                        echo "$service" ;;  # fallback: same name
  esac
}

poll_railway_status() {
  local service="$1"
  local max_wait="${RAILWAY_POLL_TIMEOUT:-120}"
  local interval=10
  local elapsed=0
  local status=""

  info "Polling Railway status for '$service' (max ${max_wait}s)..."

  while [ "$elapsed" -lt "$max_wait" ]; do
    local raw
    raw="$(cd "$ROOT_DIR" && railway service status --service "$service" --json 2>/dev/null || true)"

    if [ -z "$raw" ]; then
      warn "railway service status --json returned no output for '$service' (railway CLI may not support --json flag)"
      return 0  # fallback: non-fatal
    fi

    status="$(printf '%s' "$raw" | jq -r '.status // empty' 2>/dev/null || true)"

    if [ -z "$status" ]; then
      warn "Could not parse status from railway status output for '$service'"
      return 0  # fallback: non-fatal
    fi

    case "$status" in
      SUCCESS)
        ok "Railway service '$service' deployed successfully (status: $status)."
        return 0
        ;;
      FAILED|CRASHED)
        local deploy_url
        deploy_url="$(printf '%s' "$raw" | jq -r '.url // empty' 2>/dev/null || true)"
        warn "Railway service '$service' deploy ${status}. URL: ${deploy_url:-unknown}"
        return 1
        ;;
      BUILDING|DEPLOYING|INITIALIZING|QUEUED)
        info "Railway service '$service' status: $status — waiting..."
        sleep "$interval"
        elapsed=$((elapsed + interval))
        ;;
      *)
        warn "Railway service '$service' unexpected status: '$status'"
        return 0  # non-fatal for unknown states
        ;;
    esac
  done

  if [ "${NO_POLL:-0}" = "1" ]; then
    warn "Railway poll timeout for '$service' — continuing (--no-poll mode)."
    return 0
  fi
  warn "Railway poll timed out after ${max_wait}s for '$service' (last status: $status)."
  return 1
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

  if ! railway_service_exists "$service"; then
    if [ -z "$subdir" ]; then
      warn "Railway service '$service' was not found and cannot be auto-created from the repo root."
      return 1
    fi
    info "Railway service '$service' was not found; creating it."
    (cd "$ROOT_DIR" && railway add --service="$service" --json >/dev/null) \
      || { warn "railway add failed for '$service'"; return 1; }
    bootstrap_created_railway_service "$service"
  fi

  if [ -n "$subdir" ]; then
    info "Deploying from: $ROOT_DIR (Railway rootDirectory: apps/$subdir)"
    info "Running: railway up --service $service --detach"
    (cd "$ROOT_DIR" && railway up --service "$service" --detach) \
      || { warn "railway up failed for '$service'"; return 1; }
  else
    info "Deploying from: $ROOT_DIR"
    info "Running: railway up --service $service --detach"
    (cd "$ROOT_DIR" && railway up --service "$service" --detach) \
      || { warn "railway up failed for '$service'"; return 1; }
  fi

  ok "Railway deploy triggered for '$service'."
  poll_railway_status "$service" || return 1
}

deploy_railway_all() {
  # Use the real Railway service names here
  local services=(web cron-scrape-sources cron-db-maintenance cron-tag-queue cron-review-events cron-cleanup-stale cron-enrich-events)
  step "Railway — all apps"
  for service in "${services[@]}"; do
    deploy_railway "$service" || { warn "Railway deploy failed: $service"; ERRORS=$((ERRORS + 1)); }
  done
}

run_smoke_checks() {
  local db_url="${LOCAL_DB_URL:-postgresql://postgres:postgres@127.0.0.1:55322/postgres}"
  local supabase_url="${SUPABASE_URL:-}"
  local service_key="${SUPABASE_SERVICE_KEY:-}"

  step "Post-deploy smoke checks (DEPLOY_SMOKE=1)"

  # 1. Supabase functions drift check
  local fn_dirs fn_list
  fn_dirs="$(find "$ROOT_DIR/supabase/functions" -maxdepth 1 -mindepth 1 -type d -not -name '_shared' \
    -exec sh -c '[ -f "$1/index.ts" ] && basename "$1"' sh {} \; | sort)"
  fn_list="$(supabase functions list --json 2>/dev/null | jq -r '.[].name' 2>/dev/null | sort || true)"
  if [ -n "$fn_list" ] && [ "$(printf '%s\n' "$fn_dirs")" != "$(printf '%s\n' "$fn_list")" ]; then
    warn "Supabase function drift detected between filesystem and deployed functions."
    warn "Filesystem: $(printf '%s' "$fn_dirs" | tr '\n' ' ')"
    warn "Deployed:   $(printf '%s' "$fn_list" | tr '\n' ' ')"
  else
    ok "Supabase function list matches filesystem."
  fi

  # 2. Synthetic is_cron_enabled call (skip in production unless --allow-prod-smoke)
  if [ -n "$service_key" ] && [ -n "$supabase_url" ]; then
    local cron_result
    cron_result="$(curl -sf \
      -H "apikey: $service_key" \
      -H "Authorization: Bearer $service_key" \
      -H "Content-Type: application/json" \
      -d '{"p_label":"cron-tag-queue"}' \
      "${supabase_url}/rest/v1/rpc/is_cron_enabled" 2>/dev/null || true)"
    if [ -z "$cron_result" ]; then
      warn "Smoke: is_cron_enabled call returned empty — skipping (no Supabase URL/key?)"
    else
      ok "Smoke: is_cron_enabled('cron-tag-queue') = $cron_result"
    fi
  else
    info "Smoke: skipping is_cron_enabled (SUPABASE_URL or SUPABASE_SERVICE_KEY not set)"
  fi

  # 3. admin_db_health_snapshot (if a session token is available)
  # This requires an authenticated admin session — skip if no token
  info "Smoke: admin_db_health_snapshot requires an admin session token — skipping in automated context."
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

if [ "${DEPLOY_SMOKE:-0}" = "1" ]; then
  run_smoke_checks || ERRORS=$((ERRORS + 1))
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────"
if [ "$ERRORS" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}Deploy complete!${NC} All targets succeeded."
else
  echo -e "${YELLOW}${BOLD}Deploy finished with $ERRORS error(s).${NC} Check output above."
  exit 1
fi
