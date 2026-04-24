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
source "$(taskmaster_file taskmaster-state.sh)"

INPUT="$(cat)"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // ""')"
TURN_ID="$(printf '%s' "$INPUT" | jq -r '.turn_id // ""')"
PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // ""')"

is_taskmaster_internal_prompt() {
  local prompt="$1"
  [[ "$prompt" == \<hook_prompt* ]] && return 0
  [[ "$prompt" == Stop\ is\ blocked\ until\ completion\ is\ explicitly\ confirmed.* ]] && return 0
  [[ "$prompt" == Completion\ check\ before\ stopping.* ]] && return 0
  [[ "$prompt" == Goal\ not\ yet\ verified\ complete.* ]] && return 0
  [[ "$prompt" == Recent\ tool\ errors\ were\ detected.* ]] && return 0
  return 1
}

is_environment_context_only_prompt() {
  local prompt="$1"
  python3 - "$prompt" <<'PY'
import re
import sys

prompt = sys.argv[1].strip()
pattern = re.compile(r"^\s*<environment_context>.*?</environment_context>\s*$", re.DOTALL)
raise SystemExit(0 if pattern.match(prompt) else 1)
PY
}

if [[ -z "$SESSION_ID" || -z "$TURN_ID" || -z "$PROMPT" ]]; then
  exit 0
fi

if is_taskmaster_internal_prompt "$PROMPT" || is_environment_context_only_prompt "$PROMPT"; then
  exit 0
fi

STATE_PATH="$(taskmaster_turn_state_path "$SESSION_ID")"
STATE_DIR="$(dirname "$STATE_PATH")"
mkdir -p "$STATE_DIR"

TMP_FILE="$(mktemp "${TMPDIR:-/tmp}/taskmaster-turn-state.XXXXXX")"
CAPTURED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

if [[ -f "$STATE_PATH" ]]; then
  jq \
    --arg session_id "$SESSION_ID" \
    --arg turn_id "$TURN_ID" \
    --arg prompt "$PROMPT" \
    --arg captured_at "$CAPTURED_AT" \
    '.session_id = $session_id
    | .updated_at = $captured_at
    | .latest_prompt = {
        turn_id: $turn_id,
        prompt: $prompt,
        captured_at: $captured_at
      }
    | .turns = (.turns // {})
    | .turns[$turn_id] = {
        prompt: $prompt,
        captured_at: $captured_at
      }' \
    "$STATE_PATH" >"$TMP_FILE"
else
  jq -n \
    --arg session_id "$SESSION_ID" \
    --arg turn_id "$TURN_ID" \
    --arg prompt "$PROMPT" \
    --arg captured_at "$CAPTURED_AT" \
    '{
      session_id: $session_id,
      updated_at: $captured_at,
      latest_prompt: {
        turn_id: $turn_id,
        prompt: $prompt,
        captured_at: $captured_at
      },
      turns: {
        ($turn_id): {
          prompt: $prompt,
          captured_at: $captured_at
        }
      }
    }' >"$TMP_FILE"
fi

mv "$TMP_FILE" "$STATE_PATH"
