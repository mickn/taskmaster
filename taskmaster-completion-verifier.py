#!/usr/bin/env python3
"""Quiet semantic completion verifier for the Codex Stop hook."""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


DEFAULT_MODEL = "gpt-5.4-mini"
DEFAULT_TIMEOUT = 20
DEFAULT_MAX_CONTEXT_CHARS = 20000


def normalize(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n").strip()
    if not text:
        return ""
    lines = [line.rstrip() for line in text.splitlines()]
    text = "\n".join(lines)
    while "\n\n\n" in text:
        text = text.replace("\n\n\n", "\n\n")
    return text.strip()


def clip(text: str, limit: int) -> str:
    text = normalize(text)
    if len(text) <= limit:
        return text
    return text[: limit - 3].rstrip() + "..."


def tail_chars(text: str, limit: int) -> str:
    text = normalize(text)
    if len(text) <= limit:
        return text
    return "..." + text[-(limit - 3) :].lstrip()


def redact(text: str) -> str:
    patterns = [
        (r"(?i)(authorization\s*[:=]\s*bearer\s*)[A-Za-z0-9._~+/=-]+", r"\1[redacted]"),
        (r"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{12,}", r"\1[redacted]"),
        (
            r"(?i)((?:api[_-]?key|token|secret|password|client_secret|access[_-]?token|auth[_-]?header)\s*[:=]\s*[\"']?)[^\"'\s,}]+",
            r"\1[redacted]",
        ),
        (r"sk-[A-Za-z0-9_-]{16,}", "sk-[redacted]"),
        (r"lin_api_[A-Za-z0-9_-]{12,}", "lin_api_[redacted]"),
        (r"phx_[A-Za-z0-9_-]{12,}", "phx_[redacted]"),
        (r"xox[baprs]-[A-Za-z0-9-]+", "xox-[redacted]"),
    ]
    for pattern, repl in patterns:
        text = re.sub(pattern, repl, text)
    return text


def load_dotenv(path: Path) -> None:
    if os.environ.get("OPENAI_API_KEY") or not path.exists():
        return
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[len("export ") :].lstrip()
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip("\"'")
        if key and key not in os.environ:
            os.environ[key] = value


def content_text(content: Any) -> str:
    parts: list[str] = []
    if isinstance(content, list):
        for item in content:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict):
                value = item.get("text") or item.get("content")
                if isinstance(value, str):
                    parts.append(value)
    elif isinstance(content, str):
        parts.append(content)
    return normalize("\n".join(parts))


def is_context_only_user_message(text: str) -> bool:
    stripped = text.lstrip()
    return stripped.startswith("# AGENTS.md instructions for ") or stripped.startswith("<environment_context>")


def is_taskmaster_internal_prompt(text: str) -> bool:
    stripped = text.lstrip()
    return (
        stripped.startswith("<hook_prompt")
        or stripped.startswith("Stop is blocked until completion is explicitly confirmed.")
        or stripped.startswith("Completion check before stopping.")
        or stripped.startswith("Goal not yet verified complete.")
        or stripped.startswith("Recent tool errors were detected.")
    )


def transcript_excerpt(transcript_path: str, max_chars: int) -> str:
    if not transcript_path:
        return ""

    path = Path(transcript_path).expanduser()
    if not path.exists():
        return ""

    call_names: dict[str, str] = {}
    entries: list[str] = []
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not raw.strip():
            continue
        try:
            obj = json.loads(raw)
        except Exception:
            continue

        payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
        obj_type = obj.get("type")
        payload_type = payload.get("type")

        if obj_type == "response_item" and payload_type == "message":
            role = payload.get("role")
            text = content_text(payload.get("content"))
            if not role or not text:
                continue
            if role == "user" and (is_context_only_user_message(text) or is_taskmaster_internal_prompt(text)):
                continue
            entries.append(f"{role}: {clip(text, 1600)}")
            continue

        if obj_type == "response_item" and payload_type in {"function_call", "custom_tool_call"}:
            call_id = str(payload.get("call_id") or "")
            name = str(payload.get("name") or payload_type)
            args = payload.get("arguments") or payload.get("input") or ""
            call_names[call_id] = name
            entries.append(f"tool call: {name} {clip(redact(str(args)), 900)}")
            continue

        if obj_type == "event_msg" and payload_type == "exec_command_end":
            command = redact(str(payload.get("command") or ""))
            exit_code = payload.get("exit_code")
            status = payload.get("status")
            output = redact(str(payload.get("formatted_output") or payload.get("aggregated_output") or ""))
            entries.append(
                f"shell result: exit={exit_code} status={status} command={clip(command, 700)} output={clip(output, 1000)}"
            )
            continue

        if obj_type == "event_msg" and payload_type == "patch_apply_end":
            success = payload.get("success")
            changes = redact(json.dumps(payload.get("changes") or {}, ensure_ascii=False))
            entries.append(f"patch result: success={success} changes={clip(changes, 900)}")
            continue

        if obj_type == "response_item" and payload_type in {"function_call_output", "custom_tool_call_output"}:
            call_id = str(payload.get("call_id") or "")
            name = call_names.get(call_id, "tool")
            output = redact(str(payload.get("output") or ""))
            entries.append(f"tool output: {name} {clip(output, 900)}")
            continue

    return tail_chars("\n\n".join(entries), max_chars)


def output_text(response: dict[str, Any]) -> str:
    text = response.get("output_text")
    if isinstance(text, str) and text.strip():
        return text

    parts: list[str] = []
    for item in response.get("output", []) or []:
        if not isinstance(item, dict):
            continue
        for content in item.get("content", []) or []:
            if not isinstance(content, dict):
                continue
            value = content.get("text")
            if isinstance(value, str):
                parts.append(value)
    return normalize("\n".join(parts))


def verifier_error(reason: str) -> dict[str, Any]:
    return {
        "complete": False,
        "reason": f"Completion verifier could not confirm the goal is done: {reason}",
        "next_action": "Continue working or fix the verifier configuration so completion can be judged.",
        "verifier_error": reason,
    }


def call_openai(payload: dict[str, Any]) -> dict[str, Any]:
    load_dotenv(Path.home() / ".env")
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        return verifier_error("OPENAI_API_KEY is not set")

    # Codex CLI model slugs are not guaranteed to be valid OpenAI API model ids.
    # Use a stable API model by default, with an explicit env override when desired.
    model = os.environ.get("TASKMASTER_COMPLETION_MODEL") or DEFAULT_MODEL
    timeout = int(os.environ.get("TASKMASTER_COMPLETION_TIMEOUT", DEFAULT_TIMEOUT))
    max_context_chars = int(payload.get("max_context_chars") or DEFAULT_MAX_CONTEXT_CHARS)

    latest_user_message = normalize(str(payload.get("latest_user_message") or ""))
    last_assistant_message = normalize(str(payload.get("last_assistant_message") or ""))
    excerpt = transcript_excerpt(str(payload.get("transcript_path") or ""), max_context_chars)

    system = (
        "You are a strict completion judge for a Codex Stop hook. "
        "Decide whether the latest user goal for the current turn is fully accomplished by the evidence. "
        "Return complete=true only when every explicit request is satisfied, verification requested by the user is done, "
        "and the final assistant response is ready to send. If work is merely in progress, partially done, unverified, "
        "or blocked without the user explicitly accepting that, return complete=false. "
        "Do not require irrelevant extra work beyond the user's request."
    )

    user = (
        "Latest user message:\n"
        f"{latest_user_message or '(unknown)'}\n\n"
        "Last assistant message:\n"
        f"{last_assistant_message or '(empty)'}\n\n"
        "Recent transcript evidence, oldest to newest:\n"
        f"{excerpt or '(no transcript evidence available)'}"
    )

    schema = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "complete": {"type": "boolean"},
            "reason": {"type": "string"},
            "next_action": {"type": "string"},
        },
        "required": ["complete", "reason", "next_action"],
    }

    body = {
        "model": model,
        "instructions": system,
        "input": user,
        "max_output_tokens": 500,
        "store": False,
        "text": {
            "format": {
                "type": "json_schema",
                "name": "taskmaster_completion_verdict",
                "strict": True,
                "schema": schema,
            }
        },
    }

    request = urllib.request.Request(
        "https://api.openai.com/v1/responses",
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            data = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body_text = exc.read().decode("utf-8", errors="replace")
        return verifier_error(f"OpenAI API HTTP {exc.code}: {clip(body_text, 700)}")
    except Exception as exc:
        return verifier_error(str(exc))

    text = output_text(data)
    if not text:
        return verifier_error("OpenAI response did not contain output text")
    try:
        verdict = json.loads(text)
    except Exception:
        return verifier_error(f"OpenAI response was not valid JSON: {clip(text, 500)}")

    return {
        "complete": bool(verdict.get("complete")),
        "reason": normalize(str(verdict.get("reason") or "")),
        "next_action": normalize(str(verdict.get("next_action") or "")),
    }


def main() -> int:
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except Exception as exc:
        print(json.dumps(verifier_error(f"invalid verifier input: {exc}")))
        return 0

    print(json.dumps(call_openai(payload), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
