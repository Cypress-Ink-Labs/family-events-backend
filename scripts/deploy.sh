#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

args=("$@")
if [ "${1:-}" = "--all" ]; then
  args=("deploy" "--all" "--yes" "${@:2}")
elif [ "${1:-}" != "deploy" ] && [ "${1:-}" != "targets" ] && [ "${1:-}" != "validate" ] && [ "${1:-}" != "doctor" ] && [ "${1:-}" != "status" ] && [ "${1:-}" != "rollback-plan" ]; then
  args=("deploy" "$@")
fi

exec pnpm --filter @family-events/deploy-cli cli "${args[@]}"
