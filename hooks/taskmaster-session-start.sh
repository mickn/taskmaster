#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

taskmaster_file() {
  local name="$1"
  if [[ -f "$SCRIPT_DIR/$name" ]]; then
    printf '%s/%s\n' "$SCRIPT_DIR" "$name"
    return 0
  fi
  if [[ -f "$SCRIPT_DIR/../$name" ]]; then
    printf '%s/%s\n' "$SCRIPT_DIR/../" "$name"
    return 0
  fi
  printf 'taskmaster file not found: %s\n' "$name" >&2
  return 1
}

# shellcheck disable=SC1090
source "$(taskmaster_file taskmaster-compliance-prompt.sh)"

INPUT="$(cat)"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown-session"')"
DONE_SIGNAL="TASKMASTER_DONE::${SESSION_ID}"

build_taskmaster_session_contract "$DONE_SIGNAL"
