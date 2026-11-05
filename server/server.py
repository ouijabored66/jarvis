#!/usr/bin/env python3
"""Jarvis server: local voice/text assistant for an iPhone app and an Apple Watch Shortcut.

Runs on 127.0.0.1:4100. Tailscale Serve puts it on https://<your-pc>.<your-tailnet>.ts.net (tailnet only).
Every request needs the token from config.json (Authorization: Bearer <token>).

  POST /api/text   JSON {"text": "..."} or a plain-text body  ->  JSON {"say": "...", "saved": bool}
                   add ?audio=1 to also get {"audio": "<base64 wav>"}
  POST /api/ask    raw audio body (m4a/webm/wav)  ->  NDJSON stream:
                   {"heard": "..."} then {"say": "<sentence>", "audio": "<b64 wav>"} per sentence, then {"done": true}
  GET  /api/status ->  {"ok": true, "voice": "...", "voices": [...]}
  POST /api/voice  JSON {"voice": "bm_george"}  ->  saves the chosen voice
  POST /api/reset  starts a fresh conversation

The thinking side is Claude Code with NO tools: Jarvis can answer and save a note, nothing else.
"""
import base64, hmac, json, os, re, secrets, subprocess, sys, tempfile, threading, time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOME = os.path.expanduser("~")
DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.path.join(DIR, "config.json")
INBOX = os.path.join(DIR, "inbox")
LOG = os.path.join(DIR, "logs", "jarvis.log")
EMPTY = os.path.join(DIR, "empty")
for d in (INBOX, os.path.dirname(LOG), EMPTY):
    os.makedirs(d, exist_ok=True)


def log(msg):
    with open(LOG, "a") as f:
        f.write("%s %s\n" % (datetime.now().isoformat(timespec="seconds"), msg))


def load_config():
    if not os.path.exists(CONFIG):
        cfg = {"token": secrets.token_urlsafe(24), "voice": "bm_george", "speed": 1.05,
               "address": "sir", "port": 4100}
        old = os.umask(0o077)
        with open(CONFIG, "w") as f:
            json.dump(cfg, f, indent=2)
        os.umask(old)
    return json.load(open(CONFIG))


cfg = load_config()
if cfg.get("ffmpeg_dir"):
    os.environ["PATH"] = cfg["ffmpeg_dir"] + os.pathsep + os.environ.get("PATH", "")
NO_WINDOW = {"creationflags": 0x08000000} if os.name == "nt" else {}   # CREATE_NO_WINDOW


def save_config():
    old = os.umask(0o077)
    with open(CONFIG, "w") as f:
        json.dump(cfg, f, indent=2)
    os.umask(old)


# ---------------------------------------------------------------- workers
class Worker:
    """A long-running JSON-lines child process (hear or speak)."""

    def __init__(self, name, python, script):
        self.name, self.cmd = name, [python, "-I", script]
        self.lock = threading.Lock()
        self.proc = None
        self.info = {}

    def _start(self):
        self.proc = subprocess.Popen(self.cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=open(os.path.join(DIR, "logs", self.name + ".err"), "a"),
                                     text=True, bufsize=1, cwd=os.path.dirname(self.cmd[2]), **NO_WINDOW)
        self.info = json.loads(self.proc.stdout.readline() or "{}")
        log("%s worker ready" % self.name)

    def call(self, req):
        with self.lock:
            for attempt in (1, 2):
                try:
                    if not self.proc or self.proc.poll() is not None:
                        self._start()
                    self.proc.stdin.write(json.dumps(req) + "\n")
                    self.proc.stdin.flush()
                    line = self.proc.stdout.readline()
                    if not line:
                        raise RuntimeError("worker exited")
                    return json.loads(line)
                except Exception as e:
                    log("%s worker error: %s" % (self.name, e))
                    try:
                        self.proc.kill()
                    except Exception:
                        pass
                    self.proc = None
            return {"error": "%s unavailable" % self.name}


def venv_python(name):
    """Python inside a worker's venv (Linux: .venv/bin/python, Windows: .venv\\Scripts\\python.exe)."""
    win = os.path.join(DIR, name, ".venv", "Scripts", "python.exe")
    return win if os.name == "nt" else os.path.join(DIR, name, ".venv", "bin", "python")


hear = Worker("hear", venv_python("hear"), os.path.join(DIR, "hear", "worker.py"))
speak = Worker("speak", venv_python("speak"), os.path.join(DIR, "speak", "worker.py"))


# ---------------------------------------------------------------- speaker lock (optional)
# Enroll your voice from the app (tailnet + app token only). Once 3 clips are enrolled, /api/ask only
# accepts audio that matches your voiceprint. Set "speaker_lock": false in config.json to switch it off.
VOICEPRINT = os.path.join(DIR, "voiceprint.json")
ENROLL_NEEDED, ENROLL_MAX = 3, 8
_vp_lock = threading.Lock()


def _vp_clips():
    try:
        return [c for c in json.load(open(VOICEPRINT)).get("clips", []) if isinstance(c, list)]
    except Exception:
        return []


def _vp_write(clips):
    old = os.umask(0o077)
    try:
        with open(VOICEPRINT, "w") as f:
            json.dump({"clips": clips[-ENROLL_MAX:]}, f)
    finally:
        os.umask(old)


def voiceprint():
    """Normalised average of the enrolled clips, or None when the lock is off / not enrolled yet."""
    if cfg.get("speaker_lock", True) is False:
        return None
    with _vp_lock:
        clips = _vp_clips()
    if len(clips) < ENROLL_NEEDED:
        return None
    n = len(clips[0])
    avg = [sum(c[i] for c in clips if len(c) == n) / len(clips) for i in range(n)]
    norm = sum(x * x for x in avg) ** 0.5 or 1.0
    return [x / norm for x in avg]


def tts(text):
    out = speak.call({"text": text, "voice": cfg.get("voice", "bm_george"), "speed": cfg.get("speed", 1.05)})
    return out.get("wav_b64")


# ---------------------------------------------------------------- the brain (Claude Code, no tools)
# The desktop dual-boots; describe whichever OS this server is running on.
import getpass
PC_DESC = cfg.get("pc_description") or "this PC, running %s right now, user %s" % (
    "Windows" if os.name == "nt" else "Linux", getpass.getuser())


def persona():
    who = cfg.get("address", "sir")
    owner = cfg.get("name", "your owner")
    return f"""You are Jarvis, {owner}'s personal assistant, in the spirit of Tony Stark's AI: calm, precise,
quietly witty, unfailingly polite, with a light British manner. Address him as "{who}" now and then, not every line.
He talks to you from his iPhone app, Apple Watch or Windows PC, usually by voice, sometimes typed.

How to answer: lead with the answer in a short first sentence. Plain, direct words. One to three short
sentences unless he asks for more. Written for the ear: no lists, no markdown, no symbols, no links,
no file names, no emoji. Say numbers, times, dates and money the way a person says them.
Dry, warm wit is welcome; drop it completely when the topic is serious (health, money trouble, grief, faith).
Never guess a fact. When inferring, say "my guess is". If you don't know, say so plainly.

What you can do yourself: answer from your own knowledge and this conversation, and save a note for him.
What you can do with his approval: run a task on his PC ({PC_DESC}). Examples: rip the
disc in the drive, check disk space, restart Jellyfin, start a backup, check what's running, look up files.
You are running on that system right now, so tasks for it are yours to propose. You can't reach the other OS
while it is shut down; if he asks about it, say so.
When he asks for something on the PC, do NOT pretend it's done. Put the task in the DO line, written as a clear,
specific instruction for an assistant working on the PC, and in SAY tell him in one short sentence what you'll do
and ask him to approve it in the app. A separate assistant carries it out only after he taps Approve.
Never put purchases, payments, sending messages or email, posting online, deleting personal files or account
changes in DO; for those, tell him to do it himself or from his Claude session. Never claim you did something.

Reply in EXACTLY these four lines and nothing else:
SAY: what you say to him
SAVE: a short note to save for later, or NONE
PRIVATE: YES if the reply should not be read aloud in front of others (money, health, passwords), else NO
DO: the task for the PC, or NONE"""


def find_claude():
    """Locate the Claude Code CLI on Linux or Windows."""
    import shutil
    for c in (os.path.join(HOME, ".local", "bin", "claude"), os.path.join(HOME, ".local", "bin", "claude.exe"),
              shutil.which("claude") or "", shutil.which("claude.exe") or ""):
        if c and os.path.isfile(c):
            return c
    raise FileNotFoundError("Claude Code CLI not found")


def now_text():
    n = datetime.now()
    hour = n.hour % 12 or 12
    where = (" in %s" % cfg["location"]) if cfg.get("location") else ""
    return "It is %s, %s %d, %d, %d:%02d %s%s." % (
        n.strftime("%A"), n.strftime("%B"), n.day, n.year, hour, n.minute, "AM" if n.hour < 12 else "PM", where)


class Brain:
    RECYCLE_TURNS, RECYCLE_IDLE, TURN_TIMEOUT = 8, 600, 70

    def __init__(self):
        self.lock = threading.Lock()
        self.proc, self.dead, self.turns, self.last = None, True, 0, 0.0

    def _start(self):
        claude = find_claude()
        self.proc = subprocess.Popen(
            [claude, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
             "--model", "sonnet", "--tools", "", "--strict-mcp-config", "--setting-sources", "project",
             "--no-session-persistence", "--disable-slash-commands", "--system-prompt", persona()],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(os.path.join(DIR, "logs", "claude.err"), "a"),
            text=True, bufsize=1, cwd=EMPTY, encoding="utf-8", **NO_WINDOW)
        self.dead, self.turns = False, 0
        log("brain started")

    def _stop(self):
        self.dead = True
        if self.proc:
            try:
                self.proc.kill()
            except Exception:
                pass
        self.proc = None

    def reset(self):
        with self.lock:
            self._stop()

    def ask(self, text):
        with self.lock:
            now = time.time()
            if (self.dead or not self.proc or self.proc.poll() is not None
                    or self.turns >= self.RECYCLE_TURNS or now - self.last > self.RECYCLE_IDLE):
                self._stop()
                self._start()
            self.last = now
            context = now_text()
            msg = {"type": "user", "message": {"role": "user", "content": f"[{context}]\n{text}"}}
            result = {}
            timer = threading.Timer(self.TURN_TIMEOUT, self._stop)
            timer.start()
            try:
                self.proc.stdin.write(json.dumps(msg) + "\n")
                self.proc.stdin.flush()
                for line in self.proc.stdout:
                    try:
                        d = json.loads(line)
                    except ValueError:
                        continue
                    if d.get("type") == "result":
                        result = d
                        break
            except Exception as e:
                log("brain error: %s" % e)
                self._stop()
            finally:
                timer.cancel()
            if not result or result.get("is_error"):
                self._stop()
                return None
            self.turns += 1
            return result.get("result", "")


brain = Brain()


def parse_reply(raw):
    say, save, private, do = "", "", False, ""
    for line in (raw or "").splitlines():
        m = re.match(r"\s*(SAY|SAVE|PRIVATE|DO)\s*:\s*(.*)", line)
        if not m:
            if say and not save and line.strip():
                say += " " + line.strip()
            continue
        k, v = m.group(1), m.group(2).strip()
        if k == "SAY":
            say = v
        elif k == "SAVE":
            save = "" if v.upper() == "NONE" else v
        elif k == "DO":
            do = "" if v.upper().strip(". ") == "NONE" else v
        else:
            private = v.upper().startswith("Y")
    if not say:
        say = (raw or "").strip() or "I'm sorry, sir, I didn't manage an answer that time."
    return say, save, private, do


def save_note(note, asked):
    if not note:
        return False
    fn = os.path.join(INBOX, datetime.now().strftime("%Y%m%d-%H%M%S") + ".txt")
    with open(fn, "w") as f:
        f.write("Asked: %s\nNote: %s\n" % (asked, note))
    return True


def think(text, via="app"):
    raw = brain.ask(text)
    if raw is None:
        raw = brain.ask(text)  # one retry on a fresh session
    say, save, private, do = parse_reply(raw)
    saved = save_note(save, text)
    action = actions.create(do, text, via) if do else None
    log("Q: %s | A: %s%s%s" % (text[:200], say[:200], " [note saved]" if saved else "",
                               " [action %s proposed]" % action["id"] if action else ""))
    return say, saved, private, action


# ---------------------------------------------------------------- PC actions (run only after Approve in the app)
ACT_PROMPT = """You are carrying out ONE task on the owner's PC that he approved from his phone through Jarvis.
Do exactly that task and nothing more. If it turns out to need anything risky or outside the task
(purchases, sending messages, deleting personal files, account or security changes), stop and explain instead.
Follow the instructions in ~/CLAUDE.md (for example the DVD ripping steps). Long jobs: start them in the
background (""" + ("a detached Start-Process or a one-time scheduled task" if os.name == "nt" else "systemd-run --user") + """)
and report that they started, rather than waiting for hours.
End your reply with one final line starting with SPOKEN: and one or two plain sentences for Jarvis to say out
loud (no markdown, no file paths, numbers written for the ear)."""


class Actions:
    TTL, RUN_TIMEOUT = 3600, 1800

    def __init__(self):
        self.lock = threading.Lock()
        self.path = os.path.join(DIR, "actions.json")
        try:
            self.items = json.load(open(self.path))
        except Exception:
            self.items = {}
        for a in self.items.values():          # anything mid-run when the server stopped didn't finish
            if a["status"] == "running":
                a["status"], a["result"] = "failed", "Jarvis restarted before this finished."

    def _save(self):
        with open(self.path, "w") as f:
            json.dump(self.items, f, indent=1)

    def _expire(self):
        now = time.time()
        for a in self.items.values():
            if a["status"] == "pending" and now - a["created"] > self.TTL:
                a["status"] = "expired"
        # keep the last 50
        for k in sorted(self.items, key=lambda k: self.items[k]["created"])[:-50]:
            del self.items[k]

    def create(self, task, asked, via):
        with self.lock:
            self._expire()
            aid = secrets.token_hex(4)
            self.items[aid] = {"id": aid, "task": task[:1000], "asked": asked[:500], "via": via,
                               "status": "pending", "created": time.time(), "result": "", "spoken": ""}
            self._save()
            return dict(self.items[aid])

    def get(self, aid):
        with self.lock:
            self._expire()
            a = self.items.get(aid)
            return dict(a) if a else None

    def recent(self):
        with self.lock:
            self._expire()
            return sorted((dict(a) for a in self.items.values()), key=lambda a: -a["created"])[:20]

    def cancel(self, aid):
        with self.lock:
            a = self.items.get(aid)
            if not a or a["status"] != "pending":
                return False
            a["status"] = "cancelled"
            self._save()
            return True

    def approve(self, aid):
        with self.lock:
            self._expire()
            a = self.items.get(aid)
            if not a or a["status"] != "pending":
                return False
            a["status"], a["approved"] = "running", time.time()
            self._save()
        log("ACTION %s approved: %s" % (aid, a["task"][:300]))
        threading.Thread(target=self._run, args=(aid,), daemon=True).start()
        return True

    def _run(self, aid):
        task = self.items[aid]["task"]
        status, text = "failed", ""
        try:
            p = subprocess.run([find_claude(), "-p", task, "--permission-mode", "auto", "--output-format", "json",
                                "--append-system-prompt", ACT_PROMPT],
                               cwd=HOME, capture_output=True, text=True, encoding="utf-8",
                               timeout=self.RUN_TIMEOUT, **NO_WINDOW)
            try:
                d = json.loads(p.stdout or "{}")
                text = d.get("result", "") or ""
                status = "failed" if d.get("is_error") else "done"
            except ValueError:
                text = (p.stdout or p.stderr or "")[-2000:]
                status = "done" if p.returncode == 0 else "failed"
        except subprocess.TimeoutExpired:
            text = "It ran longer than thirty minutes, so I stopped it."
        except Exception as e:
            text = "It couldn't start: %s" % e
        spoken = ""
        m = re.search(r"SPOKEN:\s*(.+)", text)
        if m:
            spoken, text = m.group(1).strip(), text[:m.start()].strip()
        if not spoken:
            spoken = ("Done, sir." if status == "done" else "That didn't work, sir. The details are in the app.")
        with self.lock:
            a = self.items[aid]
            a.update(status=status, result=text[-4000:], spoken=spoken, finished=time.time())
            self._save()
        with open(os.path.join(DIR, "logs", "actions.log"), "a") as f:
            f.write("%s %s %s\nTASK: %s\nRESULT: %s\nSPOKEN: %s\n\n" % (
                datetime.now().isoformat(timespec="seconds"), aid, status, task, text[-4000:], spoken))
        log("ACTION %s %s" % (aid, status))


actions = Actions()


def sentences(text):
    parts = re.split(r"(?<=[.!?])\s+", text.strip())
    return [p for p in parts if p]


# ---------------------------------------------------------------- guard (lockout + rate limits)
# Jarvis can be reached from the internet through Tailscale Funnel, so:
#  - 5 wrong tokens from one address -> that address is locked out for an hour
#  - each token: at most 20 questions a minute and 300 a day
#  - public (Funnel) requests may only use the talking routes
LOCK_AFTER, LOCK_SECS = 5, 3600
PER_MIN, PER_DAY = 20, 300
PUBLIC_ROUTES = ("/api/text", "/api/ask", "/api/status")
_guard = threading.Lock()
_fails, _locked, _hits = {}, {}, {}


def tokens():
    """Named tokens: 'app' (iPhone app) plus any in cfg['tokens'] (e.g. 'watch')."""
    t = {"app": cfg["token"]}
    t.update(cfg.get("tokens", {}))
    return t


def guard_check_locked(ip):
    with _guard:
        until = _locked.get(ip, 0)
        if until and until > time.time():
            return True
        _locked.pop(ip, None)
        return False


def guard_fail(ip):
    with _guard:
        n = _fails.get(ip, 0) + 1
        _fails[ip] = n
        if n >= LOCK_AFTER:
            _locked[ip] = time.time() + LOCK_SECS
            _fails.pop(ip, None)
            log("LOCKOUT %s after %d bad tokens" % (ip, n))
        else:
            log("bad token from %s (%d)" % (ip, n))


def guard_rate_ok(name):
    now = time.time()
    with _guard:
        h = [t for t in _hits.get(name, []) if now - t < 86400]
        if len([t for t in h if now - t < 60]) >= PER_MIN or len(h) >= PER_DAY:
            _hits[name] = h
            return False
        h.append(now)
        _hits[name] = h
        return True


# ---------------------------------------------------------------- HTTP
class Handler(BaseHTTPRequestHandler):
    server_version = "Jarvis/1.0"

    def log_message(self, fmt, *args):
        pass

    def _client(self):
        """Real client address (Tailscale Serve/Funnel adds X-Forwarded-For)."""
        fwd = self.headers.get("X-Forwarded-For", "")
        # last entry = the one Tailscale itself added (earlier ones can be faked by the client)
        return fwd.split(",")[-1].strip() if fwd else self.client_address[0]

    def _public(self):
        """Funnel requests come from the internet; tailnet requests carry Tailscale identity headers."""
        return not self.headers.get("Tailscale-User-Login")

    def _authed(self):
        ip = self._client()
        if guard_check_locked(ip):
            return False
        auth = self.headers.get("Authorization", "")
        tok = auth[7:].strip() if auth.lower().startswith("bearer ") else self.headers.get("X-Jarvis-Token", "")
        name = None
        for n, t in tokens().items():
            if tok and hmac.compare_digest(tok, t):
                name = n
        if not name:
            guard_fail(ip)
            return False
        self.token_name = name
        return True

    def _allowed(self):
        """Auth + route + rate limit. Sends the error itself and returns False when refused."""
        path = self.path.split("?")[0]
        if self._public() and not path.startswith(PUBLIC_ROUTES):
            self._json(404, {"error": "not found"})
            return False
        if not self._authed():
            self._json(401, {"error": "unauthorized"})
            return False
        if path.startswith(("/api/text", "/api/ask")):
            log("request %s via %s, token %s" % (path, "public Funnel" if self._public() else "tailnet", self.token_name))
        if path.startswith(("/api/text", "/api/ask")) and not guard_rate_ok(self.token_name):
            log("rate limit hit for token %s" % self.token_name)
            self._json(429, {"error": "slow down"})
            return False
        return True

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self, limit=25_000_000):
        n = int(self.headers.get("Content-Length") or 0)
        if n > limit:
            raise ValueError("too large")
        return self.rfile.read(n) if n else b""

    def do_GET(self):
        # The app installer isn't secret, so Safari can download it without the token, but only on the tailnet.
        if self._ipa_name() and not self._public():
            return self._ipa()
        if not self._allowed():
            return
        path = self.path.split("?")[0]
        if path.startswith("/api/status"):
            voices = [v for v in speak.info.get("voices", []) if v[:2] in ("bm", "bf", "am", "af")]
            out = {"ok": True, "voice": cfg.get("voice"), "voices": voices,
                   "address": cfg.get("address"), "control": self._can_control()}
            if self._can_control():                       # voiceprint details only for the app on the tailnet
                with _vp_lock:
                    n = len(_vp_clips())
                out.update(enrolled=n, enroll_needed=ENROLL_NEEDED, speaker_lock=voiceprint() is not None)
            return self._json(200, out)
        if path == "/api/actions":
            if not self._control_ok():
                return
            return self._json(200, {"actions": [self._public_action(a) for a in actions.recent()]})
        m = re.fullmatch(r"/api/action/([0-9a-f]{8})", path)
        if m:
            if not self._control_ok():
                return
            a = actions.get(m.group(1))
            if not a:
                return self._json(404, {"error": "not found"})
            out = self._public_action(a)
            if "audio=1" in self.path and a["status"] in ("done", "failed") and a.get("spoken"):
                out["audio"] = tts(a["spoken"])
            return self._json(200, out)
        self._json(404, {"error": "not found"})

    # ---- PC control: only the iPhone app's token, only over Tailscale (never through public Funnel)
    def _can_control(self):
        return getattr(self, "token_name", "") == "app" and not self._public()

    def _control_ok(self):
        if self._can_control():
            return True
        log("control refused: token %s via %s" % (getattr(self, "token_name", "?"), "public" if self._public() else "tailnet"))
        self._json(403, {"error": "PC control only works from the iPhone app over Tailscale"})
        return False

    @staticmethod
    def _public_action(a):
        return {k: a.get(k) for k in ("id", "task", "asked", "via", "status", "result", "spoken", "created")}

    def do_HEAD(self):
        if self._ipa_name() and not self._public():
            return self._ipa(head=True)
        self.send_response(404)
        self.end_headers()

    def _ipa_name(self):
        """/download/<name>.ipa for a file that really is in dist/ (no paths, no other file types)."""
        p = self.path.split("?")[0]
        if not p.startswith("/download/"):
            return None
        name = p[len("/download/"):]
        if not re.fullmatch(r"[A-Za-z0-9._-]+\.ipa", name) or not os.path.isfile(os.path.join(DIR, "dist", name)):
            return None
        return name

    def _ipa(self, head=False):
        name = self._ipa_name()
        path = os.path.join(DIR, "dist", name)
        if not os.path.isfile(path):
            return self._json(404, {"error": "not found"})
        data = open(path, "rb").read()
        self.send_response(200)
        # octet-stream + attachment so iOS Safari saves Jarvis.ipa as-is instead of treating it as a .zip
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", 'attachment; filename="%s"' % name)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if not head:
            self.wfile.write(data)

    def do_POST(self):
        if not self._allowed():
            return
        try:
            if self.path.startswith("/api/text"):
                return self._text()
            if self.path.startswith("/api/ask"):
                return self._ask()
            if self.path.startswith("/api/voice"):
                v = json.loads(self._body() or b"{}").get("voice", "")
                if v not in speak.info.get("voices", []) and speak.info:
                    return self._json(400, {"error": "unknown voice"})
                cfg["voice"] = v
                save_config()
                return self._json(200, {"ok": True, "voice": v})
            if self.path.startswith("/api/enroll"):
                if not self._control_ok():              # never from Funnel or the Watch token
                    return
                return self._enroll_reset() if self.path.split("?")[0] == "/api/enroll/reset" else self._enroll()
            if self.path.startswith("/api/reset"):
                brain.reset()
                return self._json(200, {"ok": True})
            m = re.fullmatch(r"/api/action/([0-9a-f]{8})/(approve|cancel)", self.path.split("?")[0])
            if m:
                if not self._control_ok():
                    return
                aid, verb = m.groups()
                ok = actions.approve(aid) if verb == "approve" else actions.cancel(aid)
                if not ok:
                    return self._json(409, {"error": "that action isn't waiting for approval"})
                return self._json(200, {"ok": True, "status": "running" if verb == "approve" else "cancelled"})
        except Exception as e:
            log("request error: %s" % e)
            return self._json(500, {"error": "server error"})
        self._json(404, {"error": "not found"})

    def _text(self):
        raw = self._body(100_000)
        ctype = self.headers.get("Content-Type", "")
        text = ""
        if "json" in ctype:
            text = (json.loads(raw or b"{}").get("text") or "")
        else:
            text = raw.decode("utf-8", "replace")
        text = text.strip()[:4000]
        if not text:
            return self._json(400, {"error": "empty"})
        say, saved, private, action = think(text, self.token_name)
        out = {"say": say, "saved": saved, "private": private}
        if action:
            out["action"] = {"id": action["id"], "task": action["task"]}
        if "audio=1" in self.path:
            out["audio"] = tts(say)
        self._json(200, out)

    def _hear(self, req):
        """Save the posted clip, run it through the hear worker, and always delete the clip."""
        data = self._body()
        ext = ".m4a"
        ct = self.headers.get("Content-Type", "")
        if "webm" in ct:
            ext = ".webm"
        elif "wav" in ct:
            ext = ".wav"
        fd, path = tempfile.mkstemp(suffix=ext, dir=os.path.join(DIR, "logs"))
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        try:
            return hear.call(dict(req, path=path))
        finally:
            os.remove(path)  # never keep the recording

    def _enroll(self):
        out = self._hear({"op": "enroll"})
        emb = out.get("embedding")
        if not emb:
            return self._json(400, {"error": out.get("error", "couldn't use that clip")})
        with _vp_lock:
            clips = _vp_clips() + [emb]
            _vp_write(clips)
            n = min(len(clips), ENROLL_MAX)
        log("voiceprint: clip enrolled (%d)" % n)
        self._json(200, {"ok": True, "enrolled": n, "enroll_needed": ENROLL_NEEDED,
                         "speaker_lock": voiceprint() is not None})

    def _enroll_reset(self):
        self._body()
        with _vp_lock:
            _vp_write([])
        log("voiceprint: cleared")
        self._json(200, {"ok": True, "enrolled": 0, "speaker_lock": False})

    def _ask(self):
        vp = voiceprint()
        req = {"voiceprint": vp, "threshold": float(cfg.get("speaker_threshold", 0.45))} if vp else {}
        heard = self._hear(req)
        if vp:
            log("speaker check: %s" % (heard.get("score", heard.get("rejected", heard.get("error", "?")))))
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.end_headers()

        def emit(obj):
            self.wfile.write((json.dumps(obj) + "\n").encode())
            self.wfile.flush()

        text = heard.get("text", "")
        if not text:
            emit({"heard": "", "rejected": heard.get("rejected") or heard.get("error", "unclear")})
            emit({"done": True})
            return
        emit({"heard": text})
        say, saved, private, action = think(text, self.token_name)
        reply = {"reply": say, "saved": saved, "private": private}
        if action:
            reply["action"] = {"id": action["id"], "task": action["task"]}
        emit(reply)
        for s in sentences(say):
            emit({"say": s, "audio": tts(s)})
        emit({"done": True})


def main():
    # Bind first: if another Jarvis already has the port, exit before starting workers (no orphans).
    srv = ThreadingHTTPServer(("127.0.0.1", int(cfg.get("port", 4100))), Handler)
    # Warm the workers so the first question is quick.
    threading.Thread(target=lambda: (hear.call({"path": os.devnull}), speak.call({"text": "Ready."})), daemon=True).start()
    log("listening on 127.0.0.1:%s" % cfg.get("port", 4100))
    srv.serve_forever()


if __name__ == "__main__":
    main()
