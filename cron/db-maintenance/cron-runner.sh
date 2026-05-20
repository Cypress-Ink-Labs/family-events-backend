#!/bin/sh
# Structured-logging entrypoint for Railway cron containers.
# Wraps `curl` to a Supabase edge function and emits one JSON line per run:
#   {"ts":"...","label":"cron-tag-queue","level":"info","url":"...","http":200,"duration_s":12,"body":"..."}
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

if [ -z "$URL" ]; then
  emit error "missing URL arg" 0 0 ""
  exit 0
fi

if [ -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]; then
  emit error "SUPABASE_SERVICE_ROLE_KEY not set" 0 0 ""
  exit 0
fi

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
  2*) CRON_STATUS="succeeded" ; emit info  "ok"                           "$HTTP" "$DUR" "$BODY" ;;
  0)  CRON_STATUS="failed"    ; emit error "curl failed (network/timeout)" 0      "$DUR" "$BODY" ;;
  *)  CRON_STATUS="failed"    ; emit error "non-2xx response"              "$HTTP" "$DUR" "$BODY" ;;
esac

# Persist run result to Supabase for admin UI observability (opt-in: set LOG_CRON_RUN_URL).
if [ -n "${LOG_CRON_RUN_URL:-}" ]; then
  CLEAN_BODY=$(printf '%s' "$BODY" | tr -d '\n\r' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | cut -c1-500)
  curl --silent --max-time 10 \
    -X POST \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
    "$LOG_CRON_RUN_URL" \
    -d "{\"label\":\"$LABEL\",\"status\":\"$CRON_STATUS\",\"http_status\":$HTTP,\"duration_s\":$DUR,\"body\":\"$CLEAN_BODY\"}" \
    > /dev/null 2>&1 || true
fi

exit 0
