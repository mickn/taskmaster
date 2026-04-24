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
2. **Codex Stop hook** continues the same turn once with a focused completion
   check that quotes the latest user message.
3. **Completion behavior**:
   - If the latest user goal is complete, answer normally.
   - If anything is missing, continue working instead of stopping.
   - Legacy `TASKMASTER_DONE::<session_id>` signals are still accepted for older
     sessions, but new Codex sessions do not require them.
4. **Optional verifier**:
   - If `TASKMASTER_VERIFY_COMMAND` is set, stop remains blocked until that
     command passes.
5. **Claude path** keeps the existing stop-hook enforcement based on the done
   token plus the shared compliance prompt.

## Codex Completion Check

Codex uses its native `decision: "block"` Stop hook continuation path. The
first stop attempt asks the model to compare the latest user message against
the work done. The next stop attempt is allowed through `stop_hook_active`
unless optional verification fails.

## Configuration

- `TASKMASTER_VERIFY_COMMAND`: Codex only. Require a repo verification command
  before stop is allowed.
- `TASKMASTER_VERIFY_MAX_OUTPUT` (default `4000`): Codex only. Limit verifier
  output echoed back into the hook block reason.
- `TASKMASTER_MAX` (default `0`): Claude only. Limit repeated stop warnings.

## Setup

Install and run:

```bash
bash ~/.codex/skills/taskmaster/install.sh
codex
```
