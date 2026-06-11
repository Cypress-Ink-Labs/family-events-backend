#!/bin/sh
# Structured-logging entrypoint for Railway cron containers.
# Wraps `curl` to a Supabase edge function and emits one JSON line per run:
#   {"ts":"...","label":"cron-tag-queue","level":"info","url":"...","http":200,"duration_s":12,"body":"..."}
#
# Also:
#   - Pre-flight checks IS_CRON_ENABLED_URL (PostgREST RPC) for a per-label
#     kill switch. If the RPC returns "false" the main curl is skipped. Missing
#     config, unreachable RPCs, and invalid responses fail the run.
#   - POSTs run summary to LOG_CRON_RUN_URL so admin Scheduled Jobs page can
#     render last-run status. Missing config or failed logging fails the run.
#
# Usage: cron-runner.sh <URL> <LABEL>
#   <URL>   - full edge-function URL (env-var expanded by the caller)
#   <LABEL> - short identifier for the cron job (used in log lines)
#
# Exits non-zero for missing config, failed target calls, and failed status
# logging so Railway surfaces broken cron jobs instead of showing green runs.

set -u

URL="${1:-}"
LABEL="${2:-cron}"
TS=$(date -u +%FT%TZ)
RUN_KEY="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || printf '00000000-0000-4000-8000-%012d\n' "$$")"
RUN_KEY="$(printf '%s' "$RUN_KEY" | tr '[:upper:]' '[:lower:]' | head -c 36)"
RUNNER_LOG_FILE="$(mktemp)"
EXIT_CODE=1

cleanup() {
  rm -f "$RUNNER_LOG_FILE" "${BODY_FILE:-}"
}
trap cleanup EXIT

json_escape() {
  printf '%s' "$1" \
    | tr '\n\r' '  ' \
    | tr '\011' ' ' \
    | tr -d '\000-\010\013\014\016-\037' \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

emit() {
  level="$1"
  msg="$2"
  http="$3"
  dur="$4"
  body="$5"
  ebody=$(json_escape "$body" | cut -c1-2000)
  line=$(printf '{"ts":"%s","run_key":"%s","label":"%s","level":"%s","msg":"%s","url":"%s","http":%s,"duration_s":%s,"body":"%s"}' \
    "$TS" "$RUN_KEY" "$LABEL" "$level" "$msg" "$URL" "$http" "$dur" "$ebody")
  printf '%s\n' "$line"
  printf '%s\n' "$line" >> "$RUNNER_LOG_FILE"
}

# POST run result to log-cron-run edge fn. private.railway_cron_runs.status
# only accepts 'succeeded' or 'failed'; non-2xx HTTP and skipped runs both map to 'failed'.
log_run() {
  status="$1"
  http="$2"
  dur="$3"
  body="$4"

  if [ -z "${LOG_CRON_RUN_URL:-}" ]; then
    emit error "LOG_CRON_RUN_URL not set" 0 "$dur" "$body"
    return 1
  fi
  if [ -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]; then
    emit error "SUPABASE_SERVICE_ROLE_KEY not set" 0 "$dur" "$body"
    return 1
  fi

  ebody=$(json_escape "$body" | cut -c1-2000)
  erunner=$(json_escape "$(cat "$RUNNER_LOG_FILE" 2>/dev/null || true)" | cut -c1-8000)
  payload=$(printf '{"run_key":"%s","label":"%s","status":"%s","http_status":%s,"duration_s":%s,"body":"%s","runner_log":"%s"}' \
    "$RUN_KEY" "$LABEL" "$status" "$http" "$dur" "$ebody" "$erunner")

  log_http=$(curl --silent --show-error --max-time 10 \
    -o /dev/null -w "%{http_code}" \
    -X POST \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
    "$LOG_CRON_RUN_URL" -d "$payload" 2>/dev/null || echo "000")

  case "$log_http" in
    2*) return 0 ;;
    *)  emit error "cron log failed" "$(printf '%d' "${log_http:-0}" 2>/dev/null || echo 0)" "$dur" "$body"; return 1 ;;
  esac
}

# Check the per-label DB kill switch. Returns 0 (enabled) or 1 (disabled).
# Returns 2 for config/network/response errors so the run fails hard.
is_enabled() {
  if [ -z "${IS_CRON_ENABLED_URL:-}" ]; then
    emit error "IS_CRON_ENABLED_URL not set" 0 0 ""
    return 2
  fi
  if [ -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]; then
    emit error "SUPABASE_SERVICE_ROLE_KEY not set" 0 0 ""
    return 2
  fi

  ENABLED_BODY_FILE="$(mktemp)"
  enabled_http=$(curl --silent --show-error --max-time 10 \
    -o "$ENABLED_BODY_FILE" -w "%{http_code}" \
    -X POST \
    -H 'Content-Type: application/json' \
    -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
    "$IS_CRON_ENABLED_URL" -d "$(printf '{"p_label":"%s"}' "$LABEL")" 2>/dev/null || echo "000")
  resp=$(cat "$ENABLED_BODY_FILE" 2>/dev/null || true)
  rm -f "$ENABLED_BODY_FILE"

  case "$enabled_http" in
    2*) ;;
    *) emit error "cron enabled check failed" "$(printf '%d' "${enabled_http:-0}" 2>/dev/null || echo 0)" 0 "$resp"; return 2 ;;
  esac

  # PostgREST returns scalar true/false.
  case "$(printf '%s' "$resp" | tr -d '[:space:]')" in
    false) return 1 ;;
    true)  return 0 ;;
    *)     emit error "cron enabled check returned invalid response" "$enabled_http" 0 "$resp"; return 2 ;;
  esac
}

if [ -z "$URL" ]; then
  emit error "missing URL arg" 0 0 ""
  exit 1
fi

if [ -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]; then
  emit error "SUPABASE_SERVICE_ROLE_KEY not set" 0 0 ""
  exit 1
fi

is_enabled
enabled_status=$?
case "$enabled_status" in
  0) ;;
  1) emit info "skipped (disabled)" 0 0 "disabled"; log_run "failed" 0 0 "disabled via cron_enabled toggle"; exit $? ;;
  *) exit 1 ;;
esac

emit info "starting" 0 0 ""

START=$(date +%s)
BODY_FILE=$(mktemp)
HTTP_RAW=$(curl --silent --show-error --max-time 170 \
  -o "$BODY_FILE" -w "%{http_code}" \
  -X POST \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "X-Cron-Run-Key: $RUN_KEY" \
  -H "X-Cron-Label: $LABEL" \
  "$URL" -d "$(printf '{"cron_run_key":"%s","cron_label":"%s"}' "$RUN_KEY" "$LABEL")" 2>/dev/null || echo "0")
END=$(date +%s)
DUR=$((END - START))
BODY=$(cat "$BODY_FILE" 2>/dev/null || true)

# Strip leading zeros so JSON output is valid (e.g. curl "000" -> 0, "200" -> 200).
HTTP=$(printf '%d' "${HTTP_RAW:-0}" 2>/dev/null || echo 0)

case "$HTTP" in
  2*) emit info "ok" "$HTTP" "$DUR" "$BODY"; log_run "succeeded" "$HTTP" "$DUR" "$BODY"; EXIT_CODE=$? ;;
  0)  emit error "curl failed (network/timeout)" 0 "$DUR" "$BODY"; log_run "failed" 0 "$DUR" "$BODY"; EXIT_CODE=1 ;;
  *)  emit error "non-2xx response" "$HTTP" "$DUR" "$BODY"; log_run "failed" "$HTTP" "$DUR" "$BODY"; EXIT_CODE=1 ;;
esac

exit "$EXIT_CODE"
