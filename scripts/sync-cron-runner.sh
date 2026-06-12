#!/usr/bin/env bash
# Syncs the canonical cron-runner.sh into each Railway cron service dir.
# Run after editing cron/_shared/cron-runner.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/cron/_shared/cron-runner.sh"

if [ ! -f "$SRC" ]; then
  echo "missing source: $SRC" >&2
  exit 1
fi

CRON_DIRS=(
  cron/cleanup-stale
  cron/db-maintenance
  cron/enrich-events
  cron/review-events
  cron/scrape-sources
  cron/send-reminders
  cron/tag-queue
  cron/weekly-digest
)
for dir in "${CRON_DIRS[@]}"; do
  dst="$ROOT/$dir/cron-runner.sh"
  cp "$SRC" "$dst"
  chmod +x "$dst"
  echo "synced -> $dst"
done
