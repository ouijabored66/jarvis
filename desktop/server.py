#!/usr/bin/env python3
"""Small Lumen desktop server.

Stdlib only. Listens on the LAN, checks the iPhone app's Bearer token, and
forwards text to one AI provider (or to a local Ollama). Speech stays on the
phone. The provider key never leaves this computer.

    python3 desktop/server.py
"""

from __future__ import annotations

import json
import os
import secrets
import socket
import sys
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(DIR, "config.json")
SYSTEM = "You are Lumen, a helpful voice assistant."
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
    "openrouter": ("OpenRouter", "https://openrouter.ai/api/v1/chat/completions", "openai/gpt-4o-mini"),
    "openai": ("OpenAI", "https://api.openai.com/v1/chat/completions", "gpt-4o-mini"),
}


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
    if k.startswith("sk-"):
        return "openai"
    return None


def load_config() -> dict:
    cfg = {
        "token": "",
        "provider_key": "",
        "backend": "auto",
        "ollama_url": "http://127.0.0.1:11434",
        "ollama_model": "llama3.2",
        "port": 8787,
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
                "port": int(cfg.get("port", 8787)),
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


def lan_ips() -> list[str]:
    ips = []
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ips.append(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if ip not in ips and not ip.startswith("127."):
                ips.append(ip)
    except OSError:
        pass
    return ips or ["127.0.0.1"]


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
        raise RuntimeError("unreachable") from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise RuntimeError("unreachable") from None
    try:
        obj = json.loads(body.decode() or "{}")
    except json.JSONDecodeError:
        raise RuntimeError("unreachable") from None
    return obj if isinstance(obj, dict) else {}


def forward(text: str) -> str:
    name, kind = backend()
    with LOCK:
        history = list(HISTORY)
    messages = [{"role": "system", "content": SYSTEM}]
    messages += history
    messages.append({"role": "user", "content": text})
    if kind == "ollama":
        say = ollama(messages)
    else:
        say = provider_chat(kind, messages)
    with LOCK:
        HISTORY.append({"role": "user", "content": text})
        HISTORY.append({"role": "assistant", "content": say})
        del HISTORY[:-40]
    return say


def provider_chat(kind: str, messages: list[dict]) -> str:
    _title, url, model = PROVIDERS[kind]
    key = provider_key()
    if not key:
        raise RuntimeError("nokey")
    headers = {"Content-Type": "application/json", "User-Agent": "LumenVoice"}
    if kind == "claude":
        headers["x-api-key"] = key
        headers["anthropic-version"] = "2023-06-01"
        user_msgs = [m for m in messages if m["role"] != "system"]
        payload = {"model": model, "max_tokens": 400, "system": SYSTEM, "messages": user_msgs}
    elif kind == "gemini":
        headers["x-goog-api-key"] = key
        contents = [
            {"role": "user" if m["role"] == "user" else "model", "parts": [{"text": m["content"]}]}
            for m in messages
            if m["role"] != "system"
        ]
        payload = {
            "systemInstruction": {"parts": [{"text": SYSTEM}]},
            "contents": contents,
            "generationConfig": {"maxOutputTokens": 400},
        }
    else:
        headers["Authorization"] = "Bearer " + key
        payload = {"model": model, "messages": messages, "max_tokens": 400}
    obj = post_json(url, payload, headers)
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
    text = (text or "").strip()
    if not text:
        raise RuntimeError("empty")
    return text


def ollama(messages: list[dict]) -> str:
    url = (CONFIG.get("ollama_url") or "http://127.0.0.1:11434").rstrip("/") + "/api/chat"
    payload = {
        "model": CONFIG.get("ollama_model") or "llama3.2",
        "messages": messages,
        "stream": False,
    }
    obj = post_json(url, payload, {"Content-Type": "application/json", "User-Agent": "LumenVoice"})
    text = ((obj.get("message") or {}).get("content") or "").strip()
    if not text:
        raise RuntimeError("empty")
    return text


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

    def do_GET(self):
        if not self._authed():
            return
        path = self.path.split("?")[0]
        if path.startswith("/api/status"):
            name, _kind = backend()
            # Speaker ID is not implemented in this small server.
            self._json(200, {"ok": True, "name": name, "voiceLock": False})
            return
        if path == "/api/actions":
            self._json(200, {"actions": []})
            return
        self._json(404, {"error": "not found"})

    def do_POST(self):
        if not self._authed():
            return
        path = self.path.split("?")[0]
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
                return self._json(404, {"error": "not found"})
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
        say = forward(text)
        self._json(200, {"say": say, "saved": False, "private": False})


def main() -> None:
    port = int(CONFIG.get("port") or 8787)
    name, kind = backend()
    httpd = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print("Lumen desktop server")
    print(f"  Assistant: {name}")
    if kind != "ollama" and not provider_key():
        print("  No provider key yet. Set LUMEN_PROVIDER_KEY or provider_key in desktop/config.json.")
        print("  Until then, text is sent to local Ollama if it is running.")
    print()
    print("In the iPhone app choose Run your own server and enter:")
    print()
    for ip in lan_ips():
        print(f"  URL    http://{ip}:{port}")
    print(f"  Token  {CONFIG.get('token')}")
    print()
    print("Away from home, publish this server with Tailscale (tailscale serve) or another")
    print("HTTPS address, and use that URL in the app. Don't put it on the open internet")
    print("without HTTPS. The provider key stays in desktop/config.json or LUMEN_PROVIDER_KEY.")
    print()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
        sys.exit(0)


if __name__ == "__main__":
    main()
