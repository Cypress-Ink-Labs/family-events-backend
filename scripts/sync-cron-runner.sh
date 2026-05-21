#!/usr/bin/env bash
# Syncs the canonical cron-runner.sh into each Railway cron service dir.
# Run after editing apps/_shared/cron-runner.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/apps/_shared/cron-runner.sh"

if [ ! -f "$SRC" ]; then
  echo "missing source: $SRC" >&2
  exit 1
fi

CRON_APPS=(cron-tag-queue cron-scrape-sources cron-db-maintenance)
for app in "${CRON_APPS[@]}"; do
  dst="$ROOT/apps/$app/cron-runner.sh"
  cp "$SRC" "$dst"
  chmod +x "$dst"
  echo "synced -> $dst"
done
