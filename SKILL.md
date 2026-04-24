---
name: taskmaster
description: |
  Native Codex UserPromptSubmit/Stop hooks plus a Claude stop hook
  that keep work moving until the latest user goal is complete.
author: blader
version: 5.0.0
---

# Taskmaster

Taskmaster uses native hooks to enforce completion without a wrapper process.

## How It Works

1. **Codex UserPromptSubmit hook** captures the latest external user prompt for
   the active turn.
2. **Codex Stop hook** runs a quiet semantic completion verifier on every stop
   attempt.
3. **Completion behavior**:
   - If the verifier says the latest user goal is complete, stop is allowed.
   - If anything is missing, Codex is continued in the same turn with the
     verifier's reason and next action.
   - Legacy `TASKMASTER_DONE::<session_id>` signals are accepted only when
     semantic completion verification is disabled.
4. **Optional verifier**:
   - If `TASKMASTER_VERIFY_COMMAND` is set, stop remains blocked until that
     command passes.
5. **Claude path** keeps the existing stop-hook enforcement based on the done
   token plus the shared compliance prompt.

## Codex Completion Check

Codex uses its native `decision: "block"` Stop hook continuation path. The
Stop hook runs a semantic verifier against the latest user message,
`last_assistant_message`, and recent transcript evidence. Stop remains blocked
until the verifier returns `complete: true`.

## Configuration

- `TASKMASTER_VERIFY_COMMAND`: Codex only. Require a repo verification command
  before stop is allowed.
- `TASKMASTER_VERIFY_MAX_OUTPUT` (default `4000`): Codex only. Limit verifier
  output echoed back into the hook block reason.
- `TASKMASTER_COMPLETION_MODEL`: Codex only. Override the OpenAI model used by
  the semantic completion verifier. Defaults to `gpt-5.4-mini`.
- `TASKMASTER_COMPLETION_VERIFY` (default `1`): Codex only. Set to `0`,
  `false`, `off`, or `no` to disable semantic completion verification.
- `TASKMASTER_COMPLETION_VERIFIER_COMMAND`: Codex only. Replace the built-in
  verifier with a command that reads JSON stdin and returns `complete`,
  `reason`, and `next_action`.
- `TASKMASTER_COMPLETION_MAX_CONTEXT_CHARS` (default `20000`): Codex only.
  Limit transcript context passed to the verifier.
- `TASKMASTER_MAX` (default `0`): Claude only. Limit repeated stop warnings.

## Setup

Install and run:

```bash
bash ~/.codex/skills/taskmaster/install.sh
codex
```
