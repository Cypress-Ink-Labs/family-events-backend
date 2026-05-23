#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUPABASE_CLI="$ROOT_DIR/scripts/supabase.sh"
CONFIRM_PHRASE="WIPE_LIVE_EVENTS"
ASSUME_YES=false

usage() {
  cat <<'EOF'
Usage: bash scripts/db/wipe-live-events.sh [--yes]

Wipes live event/scrape history data from the linked Supabase project:
- public.events
- public.source_runs
- public.source_scrape_queue
- public.source_extraction_traces
- public.event_tag_queue
- public.event_ai_traces
- public.event_llm_review_queue
- public.event_llm_review_traces
- private.railway_cron_runs

Also resets source health fields on public.event_sources:
- last_scraped_at = NULL
- last_status = 'pending'
- error_count = 0

Options:
  --yes, -y    Skip interactive confirmation prompt.
  --help, -h   Show this help text.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)
      ASSUME_YES=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! bash "$SUPABASE_CLI" projects list --output json | grep -q '"linked": true'; then
  echo "No linked Supabase project found. Run: bash scripts/supabase.sh link --project-ref <ref>" >&2
  exit 1
fi

COUNT_SQL=$'SELECT \'events\' AS table_name, COUNT(*)::bigint AS row_count FROM public.events\nUNION ALL SELECT \'source_runs\', COUNT(*) FROM public.source_runs\nUNION ALL SELECT \'source_scrape_queue\', COUNT(*) FROM public.source_scrape_queue\nUNION ALL SELECT \'source_extraction_traces\', COUNT(*) FROM public.source_extraction_traces\nUNION ALL SELECT \'event_tag_queue\', COUNT(*) FROM public.event_tag_queue\nUNION ALL SELECT \'event_ai_traces\', COUNT(*) FROM public.event_ai_traces\nUNION ALL SELECT \'event_llm_review_queue\', COUNT(*) FROM public.event_llm_review_queue\nUNION ALL SELECT \'event_llm_review_traces\', COUNT(*) FROM public.event_llm_review_traces\nUNION ALL SELECT \'private.railway_cron_runs\', COUNT(*) FROM private.railway_cron_runs\nUNION ALL SELECT \'event_sources\', COUNT(*) FROM public.event_sources\nORDER BY table_name;'

echo "Linked project:"
bash "$SUPABASE_CLI" projects list --output json
echo
echo "Counts before wipe:"
bash "$SUPABASE_CLI" db query --linked "$COUNT_SQL"
echo

if [[ "$ASSUME_YES" != true ]]; then
  echo "Type $CONFIRM_PHRASE to wipe live data:"
  read -r CONFIRM_INPUT
  if [[ "$CONFIRM_INPUT" != "$CONFIRM_PHRASE" ]]; then
    echo "Aborted." >&2
    exit 1
  fi
fi

SQL_FILE="$(mktemp)"
trap 'rm -f "$SQL_FILE"' EXIT

cat > "$SQL_FILE" <<'SQL'
BEGIN;

TRUNCATE TABLE
  public.events,
  public.source_scrape_queue,
  public.source_runs,
  public.source_extraction_traces,
  public.event_tag_queue,
  public.event_ai_traces,
  public.event_llm_review_queue,
  public.event_llm_review_traces,
  private.railway_cron_runs
RESTART IDENTITY CASCADE;

UPDATE public.event_sources
SET
  last_scraped_at = NULL,
  last_status = 'pending',
  error_count = 0,
  updated_at = now();

COMMIT;
SQL

echo "Wiping..."
bash "$SUPABASE_CLI" db query --linked --file "$SQL_FILE"
echo
echo "Counts after wipe:"
bash "$SUPABASE_CLI" db query --linked "$COUNT_SQL"
echo
echo "done"
