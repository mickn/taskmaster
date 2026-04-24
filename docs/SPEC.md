# Taskmaster
## Product & Technical Specification

**Version**: 5.0.0
**Scope**:
- `taskmaster/check-completion.sh`
- `taskmaster/taskmaster-compliance-prompt.sh`
- `taskmaster/taskmaster-completion-verifier.py`
- `taskmaster/taskmaster-state.sh`
- `taskmaster/hooks/taskmaster-session-start.sh`
- `taskmaster/hooks/taskmaster-user-prompt-submit.sh`
- `taskmaster/hooks/taskmaster-stop.sh`
- `taskmaster/install.sh`
- `taskmaster/uninstall.sh`

## 1. Goal

Prevent premature agent stopping while remaining usable across long-lived Codex
and Claude sessions.

Taskmaster enforces completion through hook-based feedback. Codex uses a
low-noise semantic verifier based on the latest user message, the latest
assistant message, and recent transcript evidence; Claude keeps the older
done-token contract.

Both Codex and Claude paths consume shared prompt text from
`taskmaster-compliance-prompt.sh`.

## 2. Completion Contract

A Codex turn is complete when the assistant has satisfied the latest user goal
and the Stop hook's semantic verifier returns `complete: true`.

Legacy Codex sessions that already emit `TASKMASTER_DONE::<session_id>` plus
`GOAL_ACHIEVED::yes` are still accepted only when semantic completion
verification is disabled.

### 2.1 Codex Native Stop Contract

The Codex native-hook path uses Codex's `decision: "block"` continuation path.

- Every Stop hook run checks semantic completion.
- If anything is missing, Codex continues work in the same turn with the
  verifier's reason and next action.
- Stop is allowed only when semantic completion verification passes, unless the
  verifier is explicitly disabled for compatibility mode.
- No visible completion-token protocol is required for new Codex sessions.

## 3. Architecture

### 3.1 Codex Native Hooks Path

`hooks/taskmaster-user-prompt-submit.sh`:

1. Executes as a Codex `UserPromptSubmit` hook.
2. Persists the exact user prompt for the current `session_id` + `turn_id` and
   records it as the latest external prompt for the session.
3. Ignores Taskmaster-generated continuation prompts and pure environment-only
   prompts.

`hooks/taskmaster-stop.sh`:

1. Executes as a Codex `Stop` hook.
2. Reads `session_id`, `turn_id`, `transcript_path`,
   `last_assistant_message`, `stop_hook_active`, and `cwd` from hook input.
3. Loads the exact saved turn prompt when available, then the latest saved
   prompt, and otherwise reconstructs the latest non-internal user message from
   the transcript.
4. Allows legacy completion signals that include `TASKMASTER_DONE::<session_id>`
   and `GOAL_ACHIEVED::yes` only when semantic verification is disabled.
5. Optionally runs `TASKMASTER_VERIFY_COMMAND` in the session working
   directory. Stop stays blocked until that verifier succeeds.
6. Runs the semantic completion verifier unless disabled.
7. Blocks stop with a continuation prompt until the semantic verifier returns
   `complete: true`.

`taskmaster-completion-verifier.py`:

1. Reads verifier input JSON from stdin.
2. Loads `OPENAI_API_KEY` from the environment or `~/.env`.
3. Sends the latest user message, latest assistant message, and redacted recent
   transcript evidence to the OpenAI Responses API.
4. Returns JSON with `complete`, `reason`, and `next_action`.
5. Fails closed by returning `complete: false` if the verifier cannot run or
   cannot parse a verdict.

### 3.2 Claude Stop-Hook Path

`check-completion.sh`:

1. Executes as a Claude `Stop` hook command.
2. Verifies the done token in the latest assistant message or transcript.
3. If missing, returns a blocking decision with the shared compliance prompt.
4. If present, allows stop.

## 4. Installation Behavior

`install.sh` auto-detects Codex and/or Claude and installs matching targets.
`uninstall.sh` auto-detects and removes matching targets.

Override knobs:
- `TASKMASTER_INSTALL_TARGET=auto|codex|claude|both`
- `TASKMASTER_UNINSTALL_TARGET=auto|codex|claude|both`

### 4.1 Codex Install

Install updates:
- `~/.codex/skills/taskmaster/`
- `~/.codex/config.toml` to ensure `[features] codex_hooks = true`
- `~/.codex/hooks.json` to ensure Taskmaster `UserPromptSubmit` and `Stop`
  command hooks are present

Install also removes legacy Taskmaster wrapper symlinks from:
- `~/.codex/bin/codex`
- `~/.codex/bin/codex-taskmaster`

### 4.2 Claude Install

Install updates:
- `~/.claude/skills/taskmaster/`
- `~/.claude/hooks/taskmaster-check-completion.sh`
- `~/.claude/settings.json` to ensure the stop hook is configured

## 5. Configuration

Configurable:
- `TASKMASTER_VERIFY_COMMAND`: Codex only. Require a shell verifier command
  before stop is allowed.
- `TASKMASTER_VERIFY_MAX_OUTPUT` (default `4000`): Codex only. Limit verifier
  output in hook block reasons.
- `TASKMASTER_COMPLETION_MODEL`: Codex only. Override the OpenAI model used by
  the semantic completion verifier. Defaults to `gpt-5.4-mini`.
- `TASKMASTER_COMPLETION_VERIFY` (default `1`): Codex only. Set to `0`,
  `false`, `off`, or `no` to disable semantic completion verification.
- `TASKMASTER_COMPLETION_VERIFIER_COMMAND`: Codex only. Replace the built-in
  verifier command. The command receives JSON stdin and returns JSON with
  `complete`, `reason`, and `next_action`.
- `TASKMASTER_COMPLETION_MAX_CONTEXT_CHARS` (default `20000`): Codex only.
  Limit transcript context passed to the semantic verifier.
- `TASKMASTER_MAX` (default `0`): Claude only. Warning cap in stop-hook checks.

Legacy compatibility:
- done token prefix: `TASKMASTER_DONE`

## 6. Operational Notes

- Codex enforcement is entirely native-hook based. There is no wrapper or
  expect bridge in the supported architecture.
- The stop hook avoids task segmentation based on old done-token boundaries. It
  prefers the exact prompt captured for the active `turn_id`.
- If no saved prompt exists, the stop hook falls back to the latest external
  user message found in the transcript.
- Uninstall removes Taskmaster hook entries but preserves `codex_hooks = true`
  so unrelated native-hook workflows are not broken.
