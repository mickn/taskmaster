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
# shellcheck disable=SC1090
source "$(taskmaster_file taskmaster-state.sh)"
VERIFIER_SCRIPT="$(taskmaster_file taskmaster-completion-verifier.py)"

INPUT="$(cat)"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown-session"')"
TURN_ID="$(printf '%s' "$INPUT" | jq -r '.turn_id // ""')"
TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""')"
LAST_MSG="$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // ""')"
STOP_HOOK_ACTIVE="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // "."')"
MODEL="$(printf '%s' "$INPUT" | jq -r '.model // ""')"

TRANSCRIPT="${TRANSCRIPT/#\~/$HOME}"
DONE_SIGNAL="TASKMASTER_DONE::${SESSION_ID}"
VERIFY_CMD="${TASKMASTER_VERIFY_COMMAND:-}"
VERIFY_MAX_OUTPUT="${TASKMASTER_VERIFY_MAX_OUTPUT:-4000}"
COMPLETION_VERIFIER_CMD="${TASKMASTER_COMPLETION_VERIFIER_COMMAND:-}"
COMPLETION_MAX_CONTEXT_CHARS="${TASKMASTER_COMPLETION_MAX_CONTEXT_CHARS:-20000}"
STATE_PATH="$(taskmaster_turn_state_path "$SESSION_ID")"

VERIFY_NOTE=""
if [[ -n "$VERIFY_CMD" ]]; then
  VERIFY_NOTE=$'\n\nA native verifier is enabled. Stop will remain blocked until this command passes:\n'"$VERIFY_CMD"
fi

extract_state_from_transcript() {
  local transcript_path="$1"
  [[ -f "$transcript_path" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  python3 - "$transcript_path" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1]).expanduser()
if not path.exists():
    raise SystemExit(0)


def normalize(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n").strip()
    if not text:
        return ""
    lines = [line.rstrip() for line in text.splitlines()]
    text = "\n".join(lines)
    while "\n\n\n" in text:
        text = text.replace("\n\n\n", "\n\n")
    return text.strip()


def clip(text: str, limit: int = 2500) -> str:
    if len(text) <= limit:
        return text
    return text[: limit - 3].rstrip() + "..."


def message_text_from_content(content):
    parts = []
    if isinstance(content, list):
        for item in content:
            if isinstance(item, str):
                parts.append(item)
                continue
            if not isinstance(item, dict):
                continue
            text = item.get("text")
            if isinstance(text, str) and text.strip():
                parts.append(text)
                continue
            if item.get("type") in {"input_text", "output_text"}:
                text = item.get("text")
                if isinstance(text, str) and text.strip():
                    parts.append(text)
                    continue
            inner = item.get("content")
            if isinstance(inner, str) and inner.strip():
                parts.append(inner)
    elif isinstance(content, str):
        parts.append(content)
    return normalize("\n".join(parts))


def extract_role_and_text(obj):
    if not isinstance(obj, dict):
        return None, None

    if obj.get("type") == "response_item":
        payload = obj.get("payload")
        if isinstance(payload, dict) and payload.get("type") == "message":
            role = payload.get("role")
            text = message_text_from_content(payload.get("content"))
            if role and text:
                return role, text

    role = obj.get("role")
    if isinstance(role, str):
        text = message_text_from_content(obj.get("content"))
        if not text:
            text_val = obj.get("text")
            if isinstance(text_val, str):
                text = normalize(text_val)
        if text:
            return role, text

    payload = obj.get("payload")
    if isinstance(payload, dict):
        role = payload.get("role")
        if isinstance(role, str):
            text = message_text_from_content(payload.get("content"))
            if text:
                return role, text

    message = obj.get("message")
    if isinstance(message, dict):
        role = message.get("role") or obj.get("role")
        if isinstance(role, str):
            text = message_text_from_content(message.get("content"))
            if text:
                return role, text

    return None, None


def is_context_only_user_message(text: str) -> bool:
    stripped = text.lstrip()
    if stripped.startswith("# AGENTS.md instructions for "):
        return True
    return stripped.startswith("<environment_context>")


def is_taskmaster_internal_prompt(text: str) -> bool:
    stripped = text.lstrip()
    return (
        stripped.startswith("<hook_prompt")
        or stripped.startswith("Stop is blocked until completion is explicitly confirmed.")
        or stripped.startswith("Completion check before stopping.")
        or stripped.startswith("Goal not yet verified complete.")
        or stripped.startswith("Recent tool errors were detected.")
    )


latest_user = ""
last_assistant = ""
with path.open("r", encoding="utf-8", errors="replace") as fh:
    for raw in fh:
        raw = raw.strip()
        if not raw:
            continue
        try:
            obj = json.loads(raw)
        except Exception:
            continue

        role, text = extract_role_and_text(obj)
        if role == "user" and text and not is_context_only_user_message(text) and not is_taskmaster_internal_prompt(text):
            latest_user = text
        elif role == "assistant" and text:
            last_assistant = text

print(json.dumps({"latest_user_message": clip(latest_user), "last_assistant": last_assistant}))
PY
}

run_optional_verifier() {
  local verifier_cmd="$1"
  local cwd="$2"
  local max_output="$3"

  [[ -n "$verifier_cmd" ]] || return 0
  [[ -d "$cwd" ]] || cwd="."

  local tmp_output
  tmp_output="$(mktemp "${TMPDIR:-/tmp}/taskmaster-verify.XXXXXX")"
  (
    cd "$cwd"
    bash -lc "$verifier_cmd"
  ) >"$tmp_output" 2>&1 || {
    local truncated
    truncated="$(tail -c "$max_output" "$tmp_output" 2>/dev/null || true)"
    rm -f "$tmp_output"
    jq -n --arg reason "Native verification failed. Fix the remaining issues, rerun verification, and only then stop.

Verification command:
${verifier_cmd}

Last output:
${truncated}" '{ decision: "block", reason: $reason }'
    return 1
  }

  rm -f "$tmp_output"
  return 0
}

completion_verification_enabled() {
  case "${TASKMASTER_COMPLETION_VERIFY:-1}" in
    0|false|False|FALSE|off|OFF|no|NO)
      return 1
      ;;
  esac
  return 0
}

run_completion_verifier() {
  local payload="$1"
  local cwd="$2"
  local tmp_output
  local tmp_error

  [[ -d "$cwd" ]] || cwd="."
  tmp_output="$(mktemp "${TMPDIR:-/tmp}/taskmaster-completion-verifier.XXXXXX")"
  tmp_error="$(mktemp "${TMPDIR:-/tmp}/taskmaster-completion-verifier-error.XXXXXX")"

  if [[ -n "$COMPLETION_VERIFIER_CMD" ]]; then
    (
      cd "$cwd"
      bash -lc "$COMPLETION_VERIFIER_CMD"
    ) <<<"$payload" >"$tmp_output" 2>"$tmp_error" || {
      local err
      err="$(tail -c "$VERIFY_MAX_OUTPUT" "$tmp_error" 2>/dev/null || true)"
      rm -f "$tmp_output" "$tmp_error"
      jq -n --arg reason "Completion verifier command failed: ${err}" \
        '{ complete: false, reason: $reason, next_action: "Continue working, or fix TASKMASTER_COMPLETION_VERIFIER_COMMAND." }'
      return 0
    }
  else
    "$VERIFIER_SCRIPT" <<<"$payload" >"$tmp_output" 2>"$tmp_error" || {
      local err
      err="$(tail -c "$VERIFY_MAX_OUTPUT" "$tmp_error" 2>/dev/null || true)"
      rm -f "$tmp_output" "$tmp_error"
      jq -n --arg reason "Completion verifier failed: ${err}" \
        '{ complete: false, reason: $reason, next_action: "Continue working, or fix the completion verifier." }'
      return 0
    }
  fi

  if ! jq -e 'type == "object" and has("complete")' "$tmp_output" >/dev/null 2>&1; then
    local raw
    raw="$(tail -c "$VERIFY_MAX_OUTPUT" "$tmp_output" 2>/dev/null || true)"
    rm -f "$tmp_output" "$tmp_error"
    jq -n --arg reason "Completion verifier returned invalid JSON: ${raw}" \
      '{ complete: false, reason: $reason, next_action: "Continue working, or fix the completion verifier output." }'
    return 0
  fi

  cat "$tmp_output"
  rm -f "$tmp_output" "$tmp_error"
}

load_latest_prompt_from_state() {
  local state_path="$1"
  local turn_id="$2"
  [[ -f "$state_path" ]] || return 0
  jq -r --arg turn_id "$turn_id" '.turns[$turn_id].prompt // .latest_prompt.prompt // ""' "$state_path" 2>/dev/null || true
}

has_legacy_completion_signal() {
  local text="$1"
  [[ -n "$text" ]] || return 1
  grep -Fq "$DONE_SIGNAL" <<<"$text" 2>/dev/null || return 1
  grep -Eq '(^|[[:space:]])GOAL_ACHIEVED::yes($|[[:space:]])' <<<"$text" 2>/dev/null
}

LATEST_USER_MESSAGE="$(load_latest_prompt_from_state "$STATE_PATH" "$TURN_ID")"
LAST_MSG_FALLBACK=""

if [[ -f "$TRANSCRIPT" ]]; then
  STATE_JSON="$(extract_state_from_transcript "$TRANSCRIPT" || true)"
  if [[ -n "$STATE_JSON" ]]; then
    if [[ -z "$LATEST_USER_MESSAGE" ]]; then
      LATEST_USER_MESSAGE="$(printf '%s' "$STATE_JSON" | jq -r '.latest_user_message // ""' 2>/dev/null || true)"
    fi
    LAST_MSG_FALLBACK="$(printf '%s' "$STATE_JSON" | jq -r '.last_assistant // ""' 2>/dev/null || true)"
  fi
fi

if [[ -z "$LAST_MSG" ]]; then
  LAST_MSG="$LAST_MSG_FALLBACK"
fi

run_optional_verifier "$VERIFY_CMD" "$CWD" "$VERIFY_MAX_OUTPUT" || exit 0

if ! completion_verification_enabled; then
  if has_legacy_completion_signal "$LAST_MSG"; then
    exit 0
  fi
  if [[ "$STOP_HOOK_ACTIVE" != "true" ]]; then
    REASON="$(build_taskmaster_stop_check_prompt "$LATEST_USER_MESSAGE" "The semantic completion verifier is disabled, so this is a one-pass self-check." "" "$VERIFY_NOTE")"
    jq -n --arg reason "$REASON" '{ decision: "block", reason: $reason }'
    exit 0
  fi
  exit 0
fi

VERIFIER_PAYLOAD="$(
  jq -n \
    --arg session_id "$SESSION_ID" \
    --arg turn_id "$TURN_ID" \
    --arg transcript_path "$TRANSCRIPT" \
    --arg latest_user_message "$LATEST_USER_MESSAGE" \
    --arg last_assistant_message "$LAST_MSG" \
    --arg stop_hook_active "$STOP_HOOK_ACTIVE" \
    --arg cwd "$CWD" \
    --arg model "$MODEL" \
    --arg max_context_chars "$COMPLETION_MAX_CONTEXT_CHARS" \
    '{
      session_id: $session_id,
      turn_id: $turn_id,
      transcript_path: $transcript_path,
      latest_user_message: $latest_user_message,
      last_assistant_message: $last_assistant_message,
      stop_hook_active: ($stop_hook_active == "true"),
      cwd: $cwd,
      model: $model,
      max_context_chars: ($max_context_chars | tonumber? // 20000)
    }'
)"

VERDICT="$(run_completion_verifier "$VERIFIER_PAYLOAD" "$CWD")"
COMPLETE="$(printf '%s' "$VERDICT" | jq -r '.complete // false')"

if [[ "$COMPLETE" == "true" ]]; then
  exit 0
fi

VERDICT_REASON="$(printf '%s' "$VERDICT" | jq -r '.reason // "The completion verifier says the latest user goal is not complete."' 2>/dev/null || true)"
NEXT_ACTION="$(printf '%s' "$VERDICT" | jq -r '.next_action // ""' 2>/dev/null || true)"
if [[ -z "$NEXT_ACTION" || "$NEXT_ACTION" == "null" ]]; then
  NEXT_ACTION="Continue working until the latest user goal is fully accomplished."
fi

REASON="$(build_taskmaster_stop_check_prompt "$LATEST_USER_MESSAGE" "$VERDICT_REASON" "$NEXT_ACTION" "$VERIFY_NOTE")"
jq -n --arg reason "$REASON" '{ decision: "block", reason: $reason }'
