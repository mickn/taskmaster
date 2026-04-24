# Taskmaster
## Product & Technical Specification

**Version**: 5.0.0
**Scope**:
- `taskmaster/check-completion.sh`
- `taskmaster/taskmaster-compliance-prompt.sh`
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
low-noise one-pass self-check based on the latest user message; Claude keeps
the older done-token contract.

Both Codex and Claude paths consume shared prompt text from
`taskmaster-compliance-prompt.sh`.

## 2. Completion Contract

A Codex turn is complete when the assistant has satisfied the latest user goal
and answers normally after the Stop hook's completion check.

Legacy Codex sessions that already emit `TASKMASTER_DONE::<session_id>` plus
`GOAL_ACHIEVED::yes` are still accepted.

### 2.1 Codex Native Stop Contract

The Codex native-hook path uses Codex's `decision: "block"` continuation path.

- The first Stop hook run for a turn blocks with a completion-check prompt.
- Codex receives the latest user message and decides whether the goal is done.
- If anything is missing, Codex continues work in the same turn.
- The next Stop hook run is allowed through `stop_hook_active`, unless optional
  native verification fails.
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
   and `GOAL_ACHIEVED::yes`.
5. If `stop_hook_active` is false, blocks stop and continues Codex with a
   focused completion-check prompt.
6. If `stop_hook_active` is true, allows stop unless native verification fails.
7. Optionally runs `TASKMASTER_VERIFY_COMMAND` in the session working
   directory. Stop stays blocked until that verifier succeeds.

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
