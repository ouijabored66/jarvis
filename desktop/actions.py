"""Pending computer tasks. A proposed command is stored, never run, until approve."""

from __future__ import annotations

import json
import secrets
import subprocess
import threading
import time

TTL = 600
RUN_TIMEOUT = 12

INSTRUCTION = (
    "If the user wants something done on this computer, such as opening an app, "
    "running a command, or checking disk space, do not run it. "
    'Reply with only a JSON object {"title":"short description","command":"exact shell command"}. '
    "For a normal question, reply in plain sentences and do not use that JSON."
)


def waiting_line(title: str) -> str:
    label = (title or "").strip() or "that"
    return f"Waiting for your approval on the iPhone or the Watch before I run {label}."


def proposal_from_text(text: str) -> dict | None:
    raw = (text or "").strip()
    if not raw:
        return None
    chunks = [raw]
    if "```" in raw:
        for part in raw.split("```"):
            part = part.strip()
            if part.lower().startswith("json"):
                part = part[4:].strip()
            if part:
                chunks.append(part)
    start = raw.find("{")
    end = raw.rfind("}")
    if start != -1 and end > start:
        chunks.append(raw[start : end + 1])
    for chunk in chunks:
        try:
            obj = json.loads(chunk)
        except json.JSONDecodeError:
            continue
        found = _normalize(obj)
        if found:
            return found
    return None


def proposal_from_response(kind: str, obj: dict, text: str) -> dict | None:
    found = _from_tools(kind, obj or {})
    if found:
        return found
    return proposal_from_text(text)


def tool_payload(kind: str, payload: dict) -> dict:
    """Add a propose_command tool. Ollama stays on the JSON reply only."""
    if kind == "ollama":
        return payload
    spec = {
        "type": "object",
        "properties": {
            "title": {"type": "string"},
            "command": {"type": "string"},
        },
        "required": ["title", "command"],
    }
    body = dict(payload)
    if kind == "claude":
        body["tools"] = [{
            "name": "propose_command",
            "description": "Propose a shell command for this computer. It will not run until the user approves it.",
            "input_schema": spec,
        }]
    elif kind == "gemini":
        body["tools"] = [{
            "functionDeclarations": [{
                "name": "propose_command",
                "description": "Propose a shell command for this computer. It will not run until the user approves it.",
                "parameters": spec,
            }]
        }]
    else:
        body["tools"] = [{
            "type": "function",
            "function": {
                "name": "propose_command",
                "description": "Propose a shell command for this computer. It will not run until the user approves it.",
                "parameters": spec,
            },
        }]
        body["tool_choice"] = "auto"
    return body


def _from_tools(kind: str, obj: dict) -> dict | None:
    if kind == "claude":
        for part in obj.get("content") or []:
            if not isinstance(part, dict) or part.get("type") != "tool_use":
                continue
            if part.get("name") != "propose_command":
                continue
            found = _normalize(part.get("input") if isinstance(part.get("input"), dict) else {})
            if found:
                return found
        return None
    if kind == "gemini":
        candidates = obj.get("candidates") or []
        parts = (((candidates[0] or {}).get("content") or {}).get("parts") or []) if candidates else []
        for part in parts:
            if not isinstance(part, dict):
                continue
            call = part.get("functionCall") or part.get("function_call") or {}
            if (call.get("name") or "") != "propose_command":
                continue
            args = call.get("args") or call.get("arguments") or {}
            if isinstance(args, str):
                try:
                    args = json.loads(args)
                except json.JSONDecodeError:
                    continue
            found = _normalize(args if isinstance(args, dict) else {})
            if found:
                return found
        return None
    choices = obj.get("choices") or []
    message = (choices[0] or {}).get("message") if choices else {}
    for call in (message or {}).get("tool_calls") or []:
        if not isinstance(call, dict):
            continue
        fn = call.get("function") or {}
        if (fn.get("name") or "") != "propose_command":
            continue
        args = fn.get("arguments")
        if isinstance(args, str):
            try:
                args = json.loads(args)
            except json.JSONDecodeError:
                continue
        found = _normalize(args if isinstance(args, dict) else {})
        if found:
            return found
    return None


def _normalize(obj: object) -> dict | None:
    if not isinstance(obj, dict):
        return None
    if "command" not in obj and isinstance(obj.get("action"), dict):
        obj = obj["action"]
    command = obj.get("command")
    if not isinstance(command, str):
        return None
    command = command.strip()
    if not command or len(command) > 2000 or "\x00" in command:
        return None
    title = str(obj.get("title") or obj.get("task") or "").strip()[:120] or "Run a command"
    return {"title": title, "command": command}


class Queue:
    def __init__(self) -> None:
        self._items: dict[str, dict] = {}
        self._lock = threading.Lock()

    def enqueue(self, title: str, command: str) -> dict:
        now = time.time()
        item = {
            "id": secrets.token_hex(8),
            "title": title,
            "command": command,
            "task": f"{title}: {command}",
            "created": now,
            "status": "pending",
            "result": "",
            "spoken": "",
        }
        with self._lock:
            self._expire_locked(now)
            self._items[item["id"]] = item
            return _card(item)

    def pending(self) -> list[dict]:
        with self._lock:
            self._expire_locked()
            rows = [item for item in self._items.values() if item["status"] == "pending"]
        rows.sort(key=lambda item: item["created"])
        return [_card(item) for item in rows]

    def get(self, ident: str) -> dict | None:
        with self._lock:
            self._expire_locked()
            item = self._items.get(ident)
            return _detail(item) if item else None

    def cancel(self, ident: str) -> dict | None:
        with self._lock:
            self._expire_locked()
            item = self._items.get(ident)
            if not item:
                return None
            if item["status"] == "pending":
                item["status"] = "cancelled"
                item["spoken"] = "Denied."
            return _detail(item)

    def approve(self, ident: str) -> dict | None:
        with self._lock:
            self._expire_locked()
            item = self._items.get(ident)
            if not item or item["status"] == "expired":
                return None
            if item["status"] != "pending":
                return _detail(item)
            item["status"] = "running"
            command = item["command"]
            title = item["title"]
        started = time.monotonic()
        status, output = run_command(command)
        budget = min(4.0, max(0.0, 13.0 - (time.monotonic() - started)))
        spoken = summarize(status, output, title, command, budget)
        with self._lock:
            item["status"] = status
            item["result"] = output
            item["spoken"] = spoken
            return _detail(item)

    def _expire_locked(self, now: float | None = None) -> None:
        now = time.time() if now is None else now
        for item in self._items.values():
            if item["status"] == "pending" and now - float(item["created"]) > TTL:
                item["status"] = "expired"
                item["spoken"] = "That request expired."


# Optional (title, command, output, status, budget) -> spoken text. Servers install this.
SPEAK = None

RESULT_LIMIT = 16000


def run_command(command: str) -> tuple[str, str]:
    try:
        proc = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            timeout=RUN_TIMEOUT,
        )
    except subprocess.TimeoutExpired as exc:
        out = _clip(_join(_text_of(exc.stdout), _text_of(exc.stderr)), RESULT_LIMIT)
        return "failed", out or "The command timed out."
    stdout = _text_of(proc.stdout).strip()
    stderr = _text_of(proc.stderr).strip()
    out = _clip(_join(stdout, stderr), RESULT_LIMIT)
    if proc.returncode != 0:
        if stdout:
            return "partial", out
        return "failed", out or f"The command exited with status {proc.returncode}."
    return "done", out or "Done."


def summarize(status: str, output: str, title: str, command: str = "", budget: float = 4) -> str:
    if SPEAK is not None and budget >= 1.5:
        try:
            spoken = SPEAK(title, command, output, status, budget)
        except Exception:
            spoken = None
        cleaned = _clean_spoken(spoken)
        if cleaned:
            return cleaned
    return local_summary(status, output, title, command)


def local_summary(status: str, output: str, title: str, command: str = "") -> str:
    label = (title or "that").strip() or "that"
    text = (output or "").strip()
    if text == "Done.":
        text = ""
    if status == "failed":
        line = next((ln.strip() for ln in text.splitlines() if ln.strip()), "")
        if line:
            return f"That didn't work. {line[:180]}"
        return f"That didn't work. I could not run {label}."
    df = _df_summary(text) if _looks_like_df(command, text) else ""
    if df:
        if status == "partial":
            return f"{df} One part of the disk check did not report."
        return df
    useful = _useful_lines(text)
    body = " ".join(useful)[:280]
    lead = "Done, with a note." if status == "partial" else "Done."
    if body:
        return f"{lead} {body}"
    return f"{lead} I ran {label}."


def _looks_like_df(command: str, text: str) -> bool:
    cmd = (command or "").strip().split()
    if cmd and cmd[0].endswith("df"):
        return True
    return "Filesystem" in text and "Mounted" in text and "\n/" in ("\n" + text)


def _df_summary(text: str) -> str:
    picked = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 6:
            continue
        mount = parts[-1]
        if mount not in ("/", "/home"):
            continue
        avail = pct = None
        for index, part in enumerate(parts):
            if part.endswith("%") and part[:-1].replace(".", "", 1).isdigit():
                pct = part
                avail = parts[index - 1] if index else None
                break
        if pct and avail:
            picked.append((mount, avail, pct))
    if not picked:
        return ""
    bits = []
    for mount, avail, pct in picked:
        where = "Your main drive" if mount == "/" else "Home"
        bits.append(f"{where} is {pct} full with {_pretty_size(avail)} free")
    return ". ".join(bits) + "."


def _pretty_size(token: str) -> str:
    names = {"K": "KB", "M": "MB", "G": "GB", "T": "TB"}
    if token and token[-1] in names and token[:-1].replace(".", "", 1).isdigit():
        return f"{token[:-1]} {names[token[-1]]}"
    return token


def _useful_lines(text: str) -> list[str]:
    rows = []
    for line in text.splitlines():
        line = line.strip()
        if not line or _header(line):
            continue
        rows.append(line)
        if len(rows) == 3:
            break
    return rows


def _header(line: str) -> bool:
    if any(ch.isdigit() for ch in line):
        return False
    return len(line.split()) >= 3


def _clean_spoken(text: object) -> str | None:
    if not isinstance(text, str):
        return None
    raw = text.strip().strip('"').strip()
    if not raw or raw.startswith("{") or "propose_command" in raw:
        return None
    parts: list[str] = []
    buf = ""
    for ch in raw:
        buf += ch
        if ch in ".!?":
            piece = buf.strip()
            if piece:
                parts.append(piece)
            buf = ""
            if len(parts) == 2:
                break
    if buf.strip() and len(parts) < 2:
        parts.append(buf.strip())
    spoken = " ".join(parts).strip()
    return spoken[:500] or None


def _join(stdout: str, stderr: str) -> str:
    parts = [part.strip() for part in (stdout, stderr) if part and part.strip()]
    return "\n".join(parts)


def _text_of(value: object) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return str(value)


def _clip(text: str, limit: int = 4000) -> str:
    text = (text or "").strip()
    return text[:limit]


def _card(item: dict) -> dict:
    return {
        "id": item["id"],
        "task": item["task"],
        "status": "pending",
        "asked": item["title"],
        "title": item["title"],
        "command": item["command"],
        "created": item["created"],
    }


def _detail(item: dict) -> dict:
    return {
        "id": item["id"],
        "task": item["task"],
        "status": item["status"],
        "result": item.get("result") or "",
        "spoken": item.get("spoken") or "",
        "asked": item.get("title") or "",
        "title": item.get("title") or "",
        "command": item.get("command") or "",
        "created": item.get("created"),
    }


QUEUE = Queue()
