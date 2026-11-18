#!/usr/bin/env python3
"""Lumen text server.

Stdlib only. Listens on the LAN, checks the iPhone app's Bearer token, and
forwards text to one AI provider (or to a local Ollama). Speech stays on the
phone. This process does not accept or store recordings.

    python3 server/server.py
"""

from __future__ import annotations

import importlib.util
import json
import os
import secrets
import sys
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_ACTIONS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "desktop", "actions.py")
_spec = importlib.util.spec_from_file_location("lumen_pc_actions", _ACTIONS)
actions = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(actions)

DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(DIR, "config.json")
SYSTEM = "You are Lumen, a helpful voice assistant. " + actions.INSTRUCTION + " " + actions.shell_hint()
HISTORY: list[dict] = []
LOCK = threading.Lock()

PROVIDERS = {
    "grok": ("Grok", "https://api.x.ai/v1/chat/completions", "grok-4"),
    "claude": ("Claude", "https://api.anthropic.com/v1/messages", "claude-sonnet-4-5"),
    "gemini": (
        "Gemini",
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
        "gemini-2.5-flash",
    ),
    "groq": ("Groq", "https://api.groq.com/openai/v1/chat/completions", "llama-3.3-70b-versatile"),
    "openrouter": ("OpenRouter", "https://openrouter.ai/api/v1/chat/completions", "meta-llama/llama-3.3-70b-instruct"),
}


def host_os() -> str:
    """linux or windows for this computer. Other systems report nothing."""
    return actions.host_label()


def detect(key: str) -> str | None:
    k = (key or "").strip()
    if k.startswith("xai-"):
        return "grok"
    if k.startswith("sk-ant-"):
        return "claude"
    if k.startswith("AIza"):
        return "gemini"
    if k.startswith("gsk_"):
        return "groq"
    if k.startswith("sk-or-"):
        return "openrouter"
    return None


def load_config() -> dict:
    cfg = {
        "token": "",
        "provider_key": "",
        "backend": "auto",
        "ollama_url": "http://127.0.0.1:11434",
        "ollama_model": "llama3.2",
        "port": 4100,
    }
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, encoding="utf-8") as f:
                saved = json.load(f)
            if isinstance(saved, dict):
                cfg.update(saved)
        except (OSError, json.JSONDecodeError):
            pass
    if not cfg.get("token"):
        cfg["token"] = secrets.token_urlsafe(24)
        save_config(cfg)
    if os.environ.get("LUMEN_TOKEN"):
        cfg["token"] = os.environ["LUMEN_TOKEN"]
    if os.environ.get("LUMEN_PROVIDER_KEY"):
        cfg["provider_key"] = os.environ["LUMEN_PROVIDER_KEY"]
    if os.environ.get("LUMEN_PORT"):
        try:
            cfg["port"] = int(os.environ["LUMEN_PORT"])
        except ValueError:
            pass
    if os.environ.get("LUMEN_OLLAMA_URL"):
        cfg["ollama_url"] = os.environ["LUMEN_OLLAMA_URL"]
    if os.environ.get("LUMEN_OLLAMA_MODEL"):
        cfg["ollama_model"] = os.environ["LUMEN_OLLAMA_MODEL"]
    return cfg


def save_config(cfg: dict) -> None:
    # The provider key stays in this file (or in the environment). Never print it.
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(
            {
                "token": cfg.get("token", ""),
                "provider_key": cfg.get("provider_key", ""),
                "backend": cfg.get("backend", "auto"),
                "ollama_url": cfg.get("ollama_url", "http://127.0.0.1:11434"),
                "ollama_model": cfg.get("ollama_model", "llama3.2"),
                "port": int(cfg.get("port", 4100)),
            },
            f,
            indent=2,
        )
        f.write("\n")
    os.replace(tmp, CONFIG_PATH)
    try:
        os.chmod(CONFIG_PATH, 0o600)
    except OSError:
        pass


CONFIG = load_config()


def provider_key() -> str:
    return (os.environ.get("LUMEN_PROVIDER_KEY") or CONFIG.get("provider_key") or "").strip()


def backend() -> tuple[str, str]:
    """Return (display name, kind) where kind is a provider id or 'ollama'."""
    forced = (CONFIG.get("backend") or "auto").strip().lower()
    key = provider_key()
    if forced == "ollama":
        return "Ollama", "ollama"
    kind = detect(key) if key else None
    if kind and forced in ("auto", kind):
        return PROVIDERS[kind][0], kind
    if forced in PROVIDERS and key:
        return PROVIDERS[forced][0], forced
    if kind:
        return PROVIDERS[kind][0], kind
    return "Ollama", "ollama"


def post_json(url: str, payload: dict, headers: dict, timeout: int = 60) -> dict:
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
    except urllib.error.HTTPError as e:
        # Don't include the request, the key, or the body in the raised text.
        if e.code in (401, 403):
            raise RuntimeError("rejected") from None
        if e.code == 400:
            raise RuntimeError("badrequest") from None
        raise RuntimeError("unreachable") from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise RuntimeError("unreachable") from None
    try:
        obj = json.loads(body.decode() or "{}")
    except json.JSONDecodeError:
        raise RuntimeError("unreachable") from None
    return obj if isinstance(obj, dict) else {}


def forward(text: str) -> tuple[str, dict | None]:
    _name, kind = backend()
    with LOCK:
        history = list(HISTORY)
    messages = [{"role": "system", "content": SYSTEM}]
    messages += history
    messages.append({"role": "user", "content": text})
    if kind == "ollama":
        raw, proposal = ollama(messages)
    else:
        raw, proposal = provider_chat(kind, messages)
    action = None
    if proposal:
        action = actions.QUEUE.enqueue(proposal["title"], proposal["command"])
        say = actions.waiting_line(proposal["title"])
    else:
        if not raw:
            raise RuntimeError("empty")
        say = raw
    with LOCK:
        HISTORY.append({"role": "user", "content": text})
        HISTORY.append({"role": "assistant", "content": say})
        del HISTORY[:-40]
    return say, action


def provider_chat(kind: str, messages: list[dict]) -> tuple[str, dict | None]:
    _title, url, model = PROVIDERS[kind]
    key = provider_key()
    if not key:
        raise RuntimeError("nokey")
    headers = {"Content-Type": "application/json", "User-Agent": "LumenVoice"}
    if kind == "claude":
        headers["x-api-key"] = key
        headers["anthropic-version"] = "2023-06-01"
    elif kind == "gemini":
        headers["x-goog-api-key"] = key
    else:
        headers["Authorization"] = "Bearer " + key
    payload = _chat_payload(kind, model, messages)
    try:
        obj = post_json(url, actions.tool_payload(kind, payload), headers)
    except RuntimeError as exc:
        if str(exc) != "badrequest":
            raise
        obj = post_json(url, payload, headers)
    text = _reply_text(kind, obj)
    proposal = actions.proposal_from_response(kind, obj, text)
    if not text and not proposal:
        raise RuntimeError("empty")
    return text, proposal


def _chat_payload(kind: str, model: str, messages: list[dict]) -> dict:
    if kind == "claude":
        user_msgs = [m for m in messages if m["role"] != "system"]
        return {"model": model, "max_tokens": 400, "system": SYSTEM, "messages": user_msgs}
    if kind == "gemini":
        contents = [
            {"role": "user" if m["role"] == "user" else "model", "parts": [{"text": m["content"]}]}
            for m in messages
            if m["role"] != "system"
        ]
        return {
            "systemInstruction": {"parts": [{"text": SYSTEM}]},
            "contents": contents,
            "generationConfig": {"maxOutputTokens": 400},
        }
    return {"model": model, "messages": messages, "max_tokens": 400}


def _reply_text(kind: str, obj: dict) -> str:
    if kind == "claude":
        parts = obj.get("content") or []
        text = "".join(p.get("text", "") for p in parts if isinstance(p, dict))
    elif kind == "gemini":
        candidates = obj.get("candidates") or []
        parts = (((candidates[0] or {}).get("content") or {}).get("parts") or []) if candidates else []
        text = "".join(p.get("text", "") for p in parts if isinstance(p, dict))
    else:
        choices = obj.get("choices") or []
        message = (choices[0] or {}).get("message") if choices else {}
        text = (message or {}).get("content") or ""
    return (text or "").strip()


SUMMARY_SYSTEM = (
    "Turn this finished computer command into one or two spoken sentences. "
    "Include the key numbers. Skip column headings. "
    "If it was only partly successful, say what worked and mention the problem in a few words. "
    "Do not propose another command."
)


def spoken_summary(title: str, command: str, output: str, status: str, budget: float = 4) -> str | None:
    """Ask the configured provider. Returns None so the caller can use a local summary."""
    if budget < 1.5:
        return None
    user = f"Title: {title}\nCommand: {command}\nStatus: {status}\nOutput:\n{(output or '')[:1500]}"
    timeout = max(2, int(round(budget)))
    try:
        _name, kind = backend()
        if kind == "ollama":
            url = (CONFIG.get("ollama_url") or "http://127.0.0.1:11434").rstrip("/") + "/api/chat"
            payload = {
                "model": CONFIG.get("ollama_model") or "llama3.2",
                "messages": [
                    {"role": "system", "content": SUMMARY_SYSTEM},
                    {"role": "user", "content": user},
                ],
                "stream": False,
            }
            obj = post_json(url, payload, {"Content-Type": "application/json", "User-Agent": "LumenVoice"}, timeout)
            text = ((obj.get("message") or {}).get("content") or "").strip()
        else:
            _title, url, model = PROVIDERS[kind]
            key = provider_key()
            if not key:
                return None
            headers = {"Content-Type": "application/json", "User-Agent": "LumenVoice"}
            if kind == "claude":
                headers["x-api-key"] = key
                headers["anthropic-version"] = "2023-06-01"
                payload = {
                    "model": model,
                    "max_tokens": 120,
                    "system": SUMMARY_SYSTEM,
                    "messages": [{"role": "user", "content": user}],
                }
            elif kind == "gemini":
                headers["x-goog-api-key"] = key
                payload = {
                    "systemInstruction": {"parts": [{"text": SUMMARY_SYSTEM}]},
                    "contents": [{"role": "user", "parts": [{"text": user}]}],
                    "generationConfig": {"maxOutputTokens": 120},
                }
            else:
                headers["Authorization"] = "Bearer " + key
                payload = {
                    "model": model,
                    "messages": [
                        {"role": "system", "content": SUMMARY_SYSTEM},
                        {"role": "user", "content": user},
                    ],
                    "max_tokens": 120,
                }
            obj = post_json(url, payload, headers, timeout)
            text = _reply_text(kind, obj)
    except Exception:
        return None
    if not text or text.startswith("{") or "propose_command" in text:
        return None
    return text


def _speak_result(title: str, command: str, output: str, status: str, budget: float = 4) -> str | None:
    return spoken_summary(title, command, output, status, budget)


actions.SPEAK = _speak_result


def ollama(messages: list[dict]) -> tuple[str, dict | None]:
    url = (CONFIG.get("ollama_url") or "http://127.0.0.1:11434").rstrip("/") + "/api/chat"
    payload = {
        "model": CONFIG.get("ollama_model") or "llama3.2",
        "messages": messages,
        "stream": False,
    }
    obj = post_json(url, payload, {"Content-Type": "application/json", "User-Agent": "LumenVoice"})
    text = ((obj.get("message") or {}).get("content") or "").strip()
    proposal = actions.proposal_from_text(text)
    if not text and not proposal:
        raise RuntimeError("empty")
    return text, proposal


class Handler(BaseHTTPRequestHandler):
    server_version = "LumenDesktop/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        # Don't log URLs or headers; a misconfigured client could put a key there.
        return

    def _json(self, code: int, obj: dict) -> None:
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if host_os():
            self.send_header("X-Server-OS", host_os())
        self.end_headers()
        self.wfile.write(body)

    def _authed(self) -> bool:
        header = self.headers.get("Authorization", "")
        token = header[7:].strip() if header.lower().startswith("bearer ") else ""
        expected = str(CONFIG.get("token") or "")
        if token and expected and secrets.compare_digest(token, expected):
            return True
        self._json(401, {"error": "unauthorized"})
        return False

    def _read(self) -> bytes:
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _discard_body(self) -> None:
        left = int(self.headers.get("Content-Length") or 0)
        while left > 0:
            chunk = self.rfile.read(min(left, 65536))
            if not chunk:
                break
            left -= len(chunk)

    def do_GET(self):
        if not self._authed():
            return
        path = self.path.split("?")[0]
        if len(path) > 1 and path.endswith("/"):
            path = path[:-1]
        os_name = host_os()
        if path in ("/health", "/v1/health", "/info", "/v1/info"):
            self._json(200, {"ok": True, "os": os_name})
            return
        if path in ("/models", "/v1/models"):
            self._json(200, {
                "object": "list",
                "data": [],
                "os": os_name,
                "metadata": {"os": os_name},
            })
            return
        if path.startswith("/api/status"):
            name, _kind = backend()
            # Speaker ID is not implemented in this small server.
            self._json(200, {"ok": True, "name": name, "voiceLock": False, "os": os_name})
            return
        if path == "/api/actions":
            self._json(200, {"actions": actions.QUEUE.pending()})
            return
        if path.startswith("/api/action/"):
            ident, _op = _action_path(path)
            item = actions.QUEUE.get(ident)
            if not item:
                self._json(404, {"error": "That request is no longer waiting."})
                return
            self._json(200, item)
            return
        self._json(404, {"error": "not found"})

    def do_POST(self):
        if not self._authed():
            return
        path = self.path.split("?")[0]
        if path.startswith("/api/transcribe"):
            return self._transcribe()
        ctype = (self.headers.get("Content-Type") or "").lower()
        if path.startswith(("/api/ask", "/api/enroll", "/api/voice")) or ctype.startswith("audio/"):
            self._discard_body()
            self._json(400, {"error": "This server accepts text only."})
            return
        try:
            if path.startswith("/api/text"):
                return self._text()
            if path.startswith("/api/reset"):
                self._read()
                with LOCK:
                    HISTORY.clear()
                return self._json(200, {"ok": True})
            if path.startswith("/api/action/"):
                self._read()
                return self._action(path)
        except RuntimeError as e:
            code = {"rejected": 401, "nokey": 400, "empty": 502}.get(str(e), 502)
            message = {
                "rejected": "The provider rejected the key on this computer.",
                "nokey": "Set LUMEN_PROVIDER_KEY, or run Ollama, on this computer.",
                "unreachable": "Couldn't reach the assistant from this computer.",
                "empty": "The assistant sent an empty reply.",
            }.get(str(e), "The assistant didn't answer.")
            return self._json(code, {"error": message})
        self._json(404, {"error": "not found"})

    def _transcribe(self) -> None:
        """Discard the recording. This process has no speech engine."""
        raw = self._read()
        if not raw:
            self._json(400, {"error": "empty"})
            return
        self._json(501, {"error": "This server can't turn a recording into text."})

    def _text(self) -> None:
        raw = self._read()
        ctype = self.headers.get("Content-Type", "")
        if "json" in ctype:
            try:
                text = (json.loads(raw or b"{}").get("text") or "")
            except json.JSONDecodeError:
                text = ""
        else:
            text = raw.decode("utf-8", "replace")
        text = text.strip()[:4000]
        if not text:
            self._json(400, {"error": "empty"})
            return
        say, action = forward(text)
        body = {"say": say, "saved": False, "private": False}
        if action:
            body["action"] = action
        self._json(200, body)

    def _action(self, path: str) -> None:
        ident, op = _action_path(path)
        if op == "approve":
            item = actions.QUEUE.approve(ident)
        elif op == "cancel":
            item = actions.QUEUE.cancel(ident)
        else:
            item = None
        if not item:
            self._json(404, {"error": "That request is no longer waiting."})
            return
        self._json(200, item)


def _action_path(path: str) -> tuple[str, str]:
    rest = path.split("?", 1)[0]
    if len(rest) > 1 and rest.endswith("/"):
        rest = rest[:-1]
    tail = rest[len("/api/action/"):] if rest.startswith("/api/action/") else ""
    parts = [part for part in tail.split("/") if part]
    if not parts:
        return "", ""
    return parts[0], (parts[1] if len(parts) > 1 else "")


def discard_audio() -> None:
    """Remove any recording left by an older build. New requests are text only."""
    leftover = os.path.join(DIR, "voiceprint.json")
    if os.path.isfile(leftover):
        try:
            os.remove(leftover)
        except OSError:
            pass
    logs = os.path.join(DIR, "logs")
    if not os.path.isdir(logs):
        return
    for name in os.listdir(logs):
        if name.lower().endswith((".wav", ".m4a", ".webm", ".mp3", ".caf", ".ogg")):
            try:
                os.remove(os.path.join(logs, name))
            except OSError:
                pass


def main() -> None:
    discard_audio()
    port = int(CONFIG.get("port") or 4100)
    name, kind = backend()
    httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print("Lumen server")
    print(f"  Assistant: {name}")
    if kind != "ollama" and not provider_key():
        print("  No provider key yet. Set LUMEN_PROVIDER_KEY or provider_key in server/config.json.")
        print("  Until then, text is sent to local Ollama if it is running.")
    print()
    print("In the iPhone app choose Run your own server and enter the token below.")
    print(f"  Token  {CONFIG.get('token')}")
    print()
    print(f"This process listens on http://127.0.0.1:{port}. Publish it with Tailscale")
    print("(tailscale serve) or another HTTPS address, and use that URL in the app.")
    print("Don't put it on the open internet without HTTPS.")
    print("The provider key stays in server/config.json or LUMEN_PROVIDER_KEY.")
    print()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
        sys.exit(0)


if __name__ == "__main__":
    main()
