#!/bin/sh
# Structured-logging entrypoint for Railway cron containers.
# Wraps `curl` to a Supabase edge function and emits one JSON line per run:
#   {"ts":"...","label":"cron-tag-queue","level":"info","url":"...","http":200,"duration_s":12,"body":"..."}
#
# Also:
#   - Pre-flight checks IS_CRON_ENABLED_URL (PostgREST RPC) for a per-label
#     kill switch. If the RPC returns "false" the main curl is skipped and
#     status='failed' is logged with body=disabled. Default if RPC is
#     unreachable: assume enabled (fail-open).
#   - POSTs run summary to LOG_CRON_RUN_URL so admin Scheduled Jobs page can
#     render last-run status. Best-effort; failures never fail the cron run.
#
# Usage: cron-runner.sh <URL> <LABEL>
#   <URL>   - full edge-function URL (env-var expanded by the caller)
#   <LABEL> - short identifier for the cron job (used in log lines)
#
# Always exits 0 so Railway's ON_FAILURE restart policy never triggers a
# tight retry loop — the next cron tick is the safety net.

set -u

URL="${1:-}"
LABEL="${2:-cron}"
TS=$(date -u +%FT%TZ)
RUN_KEY="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || printf '00000000-0000-4000-8000-%012d\n' "$$")"
RUN_KEY="$(printf '%s' "$RUN_KEY" | tr '[:upper:]' '[:lower:]' | head -c 36)"
RUNNER_LOG_FILE="$(mktemp)"

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

# POST run result to log-cron-run edge fn. Best-effort. private.railway_cron_runs.status
# only accepts 'succeeded' or 'failed'; non-2xx HTTP and skipped runs both map to 'failed'.
log_run() {
  status="$1"
  http="$2"
  dur="$3"
  body="$4"

  if [ -z "${LOG_CRON_RUN_URL:-}" ]; then
    return 0
  fi
  if [ -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]; then
    return 0
  fi

  ebody=$(json_escape "$body" | cut -c1-2000)
  erunner=$(json_escape "$(cat "$RUNNER_LOG_FILE" 2>/dev/null || true)" | cut -c1-8000)
  payload=$(printf '{"run_key":"%s","label":"%s","status":"%s","http_status":%s,"duration_s":%s,"body":"%s","runner_log":"%s"}' \
    "$RUN_KEY" "$LABEL" "$status" "$http" "$dur" "$ebody" "$erunner")

  curl --silent --show-error --max-time 10 \
    -o /dev/null \
    -X POST \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
    "$LOG_CRON_RUN_URL" -d "$payload" 2>/dev/null || true
}

# Check the per-label DB kill switch. Returns 0 (enabled) or 1 (disabled).
# Fail-open: any error talking to PostgREST treats the cron as enabled so a
# transient network blip can't accidentally pause every cron at once.
is_enabled() {
  if [ -z "${IS_CRON_ENABLED_URL:-}" ]; then
    return 0
  fi
  if [ -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]; then
    return 0
  fi

  resp=$(curl --silent --show-error --max-time 10 \
    -X POST \
    -H 'Content-Type: application/json' \
    -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
    "$IS_CRON_ENABLED_URL" -d "$(printf '{"p_label":"%s"}' "$LABEL")" 2>/dev/null || echo "")

  # PostgREST returns scalar `false` body when disabled.
  case "$resp" in
    false) return 1 ;;
    *)     return 0 ;;
  esac
}

if [ -z "$URL" ]; then
  emit error "missing URL arg" 0 0 ""
  exit 0
fi

if [ -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]; then
  emit error "SUPABASE_SERVICE_ROLE_KEY not set" 0 0 ""
  exit 0
fi

if ! is_enabled; then
  emit info "skipped (disabled)" 0 0 "disabled"
  log_run "failed" 0 0 "disabled via cron_enabled toggle"
  exit 0
fi

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
rm -f "$BODY_FILE"

# Strip leading zeros so JSON output is valid (e.g. curl "000" -> 0, "200" -> 200).
HTTP=$(printf '%d' "${HTTP_RAW:-0}" 2>/dev/null || echo 0)

case "$HTTP" in
  2*) emit info "ok" "$HTTP" "$DUR" "$BODY"; log_run "succeeded" "$HTTP" "$DUR" "$BODY" ;;
  0)  emit error "curl failed (network/timeout)" 0 "$DUR" "$BODY"; log_run "failed" 0 "$DUR" "$BODY" ;;
  *)  emit error "non-2xx response" "$HTTP" "$DUR" "$BODY"; log_run "failed" "$HTTP" "$DUR" "$BODY" ;;
esac

rm -f "$RUNNER_LOG_FILE"

exit 0
