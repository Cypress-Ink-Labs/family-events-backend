#!/bin/sh
# Structured-logging entrypoint for Railway cron containers.
# Wraps `curl` to a Supabase edge function and emits one JSON line per run:
#   {"ts":"...","label":"cron-tag-queue","level":"info","url":"...","http":200,"duration_s":12,"body":"..."}
#
# Also POSTs the same run summary to the `log-cron-run` Supabase edge function
# (env LOG_CRON_RUN_URL) so the admin Scheduled Jobs page can render last-run
# status + duration + HTTP code per Railway service. Best-effort: a failure
# to log never fails the cron run itself.
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

emit() {
  level="$1"
  msg="$2"
  http="$3"
  dur="$4"
  body="$5"
  ebody=$(printf '%s' "$body" | tr -d '\n\r' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | cut -c1-2000)
  printf '{"ts":"%s","label":"%s","level":"%s","msg":"%s","url":"%s","http":%s,"duration_s":%s,"body":"%s"}\n' \
    "$TS" "$LABEL" "$level" "$msg" "$URL" "$http" "$dur" "$ebody"
}

# POST run result to the log-cron-run edge function. Best-effort: silenced
# stderr, swallowed exit code. private.railway_cron_runs.status accepts only
# 'succeeded' or 'failed', so anything non-2xx maps to 'failed'.
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

  ebody=$(printf '%s' "$body" | tr -d '\n\r' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | cut -c1-2000)
  payload=$(printf '{"label":"%s","status":"%s","http_status":%s,"duration_s":%s,"body":"%s"}' \
    "$LABEL" "$status" "$http" "$dur" "$ebody")

  curl --silent --show-error --max-time 10 \
    -o /dev/null \
    -X POST \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
    "$LOG_CRON_RUN_URL" -d "$payload" 2>/dev/null || true
}

if [ -z "$URL" ]; then
  emit error "missing URL arg" 0 0 ""
  exit 0
fi

if [ -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]; then
  emit error "SUPABASE_SERVICE_ROLE_KEY not set" 0 0 ""
  exit 0
fi

printf '{"ts":"%s","label":"%s","level":"info","msg":"starting"}\n' "$TS" "$LABEL"

START=$(date +%s)
BODY_FILE=$(mktemp)
HTTP_RAW=$(curl --silent --show-error --max-time 170 \
  -o "$BODY_FILE" -w "%{http_code}" \
  -X POST \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  "$URL" -d '{}' 2>/dev/null || echo "0")
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

exit 0
