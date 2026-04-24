#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STOP_HOOK="$REPO_ROOT/hooks/taskmaster-stop.sh"
PROMPT_CAPTURE_HOOK="$REPO_ROOT/hooks/taskmaster-user-prompt-submit.sh"
TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/taskmaster-stop-test.XXXXXX")"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

TRANSCRIPT_PATH="$TEST_TMPDIR/transcript.jsonl"
VERIFIER_PATH="$TEST_TMPDIR/completion-verifier.sh"

cat > "$TRANSCRIPT_PATH" <<'EOF'
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Old finished task"}]}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Finished old task\nTASKMASTER_DONE::session-123"}]}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Implement native Codex hooks"}]}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Partial progress only."}]}}
EOF

cat > "$VERIFIER_PATH" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
if [[ "${TASKMASTER_TEST_COMPLETE:-false}" == "true" ]]; then
  jq -n '{ complete: true, reason: "all explicit requirements are satisfied", next_action: "" }'
else
  jq -n '{ complete: false, reason: "the implementation is still partial", next_action: "finish the Codex hook implementation and run verification" }'
fi
EOF
chmod +x "$VERIFIER_PATH"

HOME="$TEST_TMPDIR" "$PROMPT_CAPTURE_HOOK" <<'EOF'
{
  "session_id": "session-123",
  "turn_id": "turn-456",
  "prompt": "Implement native Codex hooks with exact prompt capture"
}
EOF

first_output="$(
  jq -n \
    --arg session_id "session-123" \
    --arg turn_id "turn-456" \
    --arg transcript_path "$TRANSCRIPT_PATH" \
    --arg last_assistant_message "Partial progress only." \
    --arg cwd "$TEST_TMPDIR" \
    '{
      session_id: $session_id,
      turn_id: $turn_id,
      transcript_path: $transcript_path,
      last_assistant_message: $last_assistant_message,
      stop_hook_active: false,
      cwd: $cwd
    }' | HOME="$TEST_TMPDIR" TASKMASTER_COMPLETION_VERIFIER_COMMAND="$VERIFIER_PATH" "$STOP_HOOK"
)"

if [[ "$(printf '%s' "$first_output" | jq -r '.decision')" != "block" ]]; then
  printf 'expected first stop attempt to block\n' >&2
  printf '%s\n' "$first_output" >&2
  exit 1
fi

first_reason="$(printf '%s' "$first_output" | jq -r '.reason')"
if ! grep -F "Goal not yet verified complete." <<<"$first_reason" >/dev/null 2>&1; then
  printf 'expected semantic verifier block reason\n' >&2
  printf '%s\n' "$first_reason" >&2
  exit 1
fi

if ! grep -F "Implement native Codex hooks with exact prompt capture" <<<"$first_reason" >/dev/null 2>&1; then
  printf 'expected current task anchor in first block reason\n' >&2
  printf '%s\n' "$first_reason" >&2
  exit 1
fi

if grep -F "Old finished task" <<<"$first_reason" >/dev/null 2>&1; then
  printf 'did not expect old completed task in first block reason\n' >&2
  printf '%s\n' "$first_reason" >&2
  exit 1
fi

if grep -F "TASKMASTER_DONE::session-123" <<<"$first_reason" >/dev/null 2>&1; then
  printf 'did not expect done token reminder in first block reason\n' >&2
  printf '%s\n' "$first_reason" >&2
  exit 1
fi

final_message='Feature is done.'

repeat_output="$(
  jq -n \
    --arg session_id "session-123" \
    --arg turn_id "turn-456" \
    --arg transcript_path "$TRANSCRIPT_PATH" \
    --arg last_assistant_message "$final_message" \
    --arg cwd "$TEST_TMPDIR" \
    '{
      session_id: $session_id,
      turn_id: $turn_id,
      transcript_path: $transcript_path,
      last_assistant_message: $last_assistant_message,
      stop_hook_active: true,
      cwd: $cwd
    }' | HOME="$TEST_TMPDIR" TASKMASTER_COMPLETION_VERIFIER_COMMAND="$VERIFIER_PATH" "$STOP_HOOK"
)"

if [[ "$(printf '%s' "$repeat_output" | jq -r '.decision')" != "block" ]]; then
  printf 'expected repeated stop attempt to keep blocking while verifier says incomplete\n' >&2
  printf '%s\n' "$repeat_output" >&2
  exit 1
fi

complete_output="$(
  jq -n \
    --arg session_id "session-123" \
    --arg turn_id "turn-456" \
    --arg transcript_path "$TRANSCRIPT_PATH" \
    --arg last_assistant_message "$final_message" \
    --arg cwd "$TEST_TMPDIR" \
    '{
      session_id: $session_id,
      turn_id: $turn_id,
      transcript_path: $transcript_path,
      last_assistant_message: $last_assistant_message,
      stop_hook_active: true,
      cwd: $cwd
    }' | HOME="$TEST_TMPDIR" TASKMASTER_COMPLETION_VERIFIER_COMMAND="$VERIFIER_PATH" TASKMASTER_TEST_COMPLETE=true "$STOP_HOOK"
)"

if [[ -n "$complete_output" ]]; then
  printf 'expected stop attempt to allow stop after semantic verifier passes\n' >&2
  printf '%s\n' "$complete_output" >&2
  exit 1
fi

verify_input="$(
  jq -n \
    --arg session_id "session-123" \
    --arg turn_id "turn-456" \
    --arg transcript_path "$TRANSCRIPT_PATH" \
    --arg last_assistant_message "$final_message" \
    --arg cwd "$TEST_TMPDIR" \
    '{
      session_id: $session_id,
      turn_id: $turn_id,
      transcript_path: $transcript_path,
      last_assistant_message: $last_assistant_message,
      stop_hook_active: true,
      cwd: $cwd
    }'
)"

verify_output="$(HOME="$TEST_TMPDIR" TASKMASTER_COMPLETION_VERIFIER_COMMAND="$VERIFIER_PATH" TASKMASTER_TEST_COMPLETE=true TASKMASTER_VERIFY_COMMAND='printf "verification failed\n" >&2; exit 1' "$STOP_HOOK" <<<"$verify_input")"

if [[ "$(printf '%s' "$verify_output" | jq -r '.decision')" != "block" ]]; then
  printf 'expected verifier failure to block stop\n' >&2
  printf '%s\n' "$verify_output" >&2
  exit 1
fi

verify_reason="$(printf '%s' "$verify_output" | jq -r '.reason')"
if ! grep -F "Native verification failed" <<<"$verify_reason" >/dev/null 2>&1; then
  printf 'expected verifier failure reason\n' >&2
  printf '%s\n' "$verify_reason" >&2
  exit 1
fi

legacy_final_message=$'Feature is done.\nGOAL_ACHIEVED::yes\nTASKMASTER_DONE::session-123'
turn_done_output="$(
  jq -n \
    --arg session_id "session-123" \
    --arg turn_id "turn-456" \
    --arg transcript_path "$TRANSCRIPT_PATH" \
    --arg last_assistant_message "$legacy_final_message" \
    --arg cwd "$TEST_TMPDIR" \
    '{
      session_id: $session_id,
      turn_id: $turn_id,
      transcript_path: $transcript_path,
      last_assistant_message: $last_assistant_message,
      stop_hook_active: false,
      cwd: $cwd
    }' | HOME="$TEST_TMPDIR" TASKMASTER_COMPLETION_VERIFIER_COMMAND="$VERIFIER_PATH" "$STOP_HOOK"
)"

if [[ "$(printf '%s' "$turn_done_output" | jq -r '.decision')" != "block" ]]; then
  printf 'expected legacy completion signal not to bypass failing semantic verifier\n' >&2
  printf '%s\n' "$turn_done_output" >&2
  exit 1
fi

echo "ok"
