# Taskmaster

Taskmaster is a completion guard for coding agents.

It addresses a common failure mode: the agent makes partial progress, writes a
summary, and stops before the user goal is actually finished.

## Philosophy

Taskmaster is built around one idea: progress is not completion.

- Evidence over narrative:
  The agent should not be allowed to stop based on a convincing summary alone.
  Completion must be explicit and machine-checkable.
- Same-session recovery:
  When a turn is incomplete, the right move is to continue in the same running
  session, not restart from scratch.
- Goal re-anchoring:
  Compliance prompts force the model back to the user’s actual request, not its
  own local notion of “good enough”.
- Low-noise enforcement:
  Native Codex hooks continue the same turn once with a focused completion
  check instead of requiring marker-token boilerplate in every final answer.

## Core Contract

A run is complete when the assistant has satisfied the latest user goal and
answers normally after the Stop hook's completion check.

Legacy `TASKMASTER_DONE::<session_id>` signals are still accepted for older
sessions, but new Codex sessions do not require them.

### Codex Native Stop Contract

The native Codex stop hook uses Codex's `decision: "block"` continuation path.
On the first stop attempt for a turn, it asks Codex to compare the latest user
message with the work already done. If anything is missing, Codex should keep
working; if the goal is complete, it can answer normally and stop on the next
pass.

## How It Works

- Codex path:
  - Installs native `UserPromptSubmit` and `Stop` hooks in `~/.codex/hooks.json`.
  - Enables Codex hook support via `~/.codex/config.toml`.
  - `UserPromptSubmit` stores the exact user prompt that opened the turn.
  - The `Stop` hook prefers the current turn's stored prompt and falls back to the latest stored prompt or transcript reconstruction only when needed.
  - The first stop attempt continues the same turn with a focused completion-check prompt.
  - The next stop attempt is allowed through Codex's `stop_hook_active` flag, unless optional verification fails.
  - Optional repo verification can be enforced with a shell command.
- Claude path:
  - Registers a `Stop` command hook.
  - The hook runs `check-completion.sh`.
  - If the done token is missing, the stop is blocked with corrective feedback.

## Install

```bash
bash ~/.codex/skills/taskmaster/install.sh
```

Auto-detection behavior:
- Installs Codex integration when `codex` or `~/.codex` exists.
- Installs Claude integration when `claude` or `~/.claude` exists.
- If both are present, installs both.
- If neither is detected, defaults to both.

Optional target override:

```bash
TASKMASTER_INSTALL_TARGET=codex bash ~/.codex/skills/taskmaster/install.sh
TASKMASTER_INSTALL_TARGET=claude bash ~/.codex/skills/taskmaster/install.sh
TASKMASTER_INSTALL_TARGET=both bash ~/.codex/skills/taskmaster/install.sh
```

Installed artifacts:
- Codex:
  - `~/.codex/skills/taskmaster/`
  - `~/.codex/config.toml` updated with `codex_hooks = true`
  - `~/.codex/hooks.json` updated with Taskmaster `UserPromptSubmit` and `Stop` hooks
- Claude:
  - `~/.claude/skills/taskmaster/`
  - `~/.claude/hooks/taskmaster-check-completion.sh`
  - Stop-hook entry added to `~/.claude/settings.json`

## Usage

### Codex

Run Codex normally:

```bash
codex [args]
```

The Taskmaster hooks activate automatically when a user prompt is submitted and
when a turn stops.

### Claude

Run Claude normally after install. Taskmaster hook enforcement is automatic.

## Configuration

- `TASKMASTER_VERIFY_COMMAND`:
  - Codex only.
  - Runs a native verifier before stop is allowed after the completion-check pass.
- `TASKMASTER_VERIFY_MAX_OUTPUT` (default `4000`):
  - Codex only.
  - Truncates verifier output echoed back into a block reason.
- `TASKMASTER_MAX` (default `0`):
  - Claude only.
  - Limits stop-block warnings in hook checks.
  - `0` means unlimited warnings.

## Uninstall

```bash
bash ~/.codex/skills/taskmaster/uninstall.sh
```

Auto-detection behavior mirrors install and removes Taskmaster from detected
Codex/Claude environments.

Optional target override:

```bash
TASKMASTER_UNINSTALL_TARGET=codex bash ~/.codex/skills/taskmaster/uninstall.sh
TASKMASTER_UNINSTALL_TARGET=claude bash ~/.codex/skills/taskmaster/uninstall.sh
TASKMASTER_UNINSTALL_TARGET=both bash ~/.codex/skills/taskmaster/uninstall.sh
```

## Requirements

- `bash`
- `jq`
- `python3`
- Codex integration:
  - Codex CLI with native hooks support enabled
- Claude integration:
  - Claude Code with `Stop` hooks enabled

## License

MIT
