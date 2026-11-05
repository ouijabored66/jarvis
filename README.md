# Jarvis

A private, self-hosted voice and text assistant in the style of Tony Stark's AI. You talk to it from an
iPhone app or an Apple Watch Shortcut; it runs on your own PC and answers out loud.

- **Hearing:** [faster-whisper](https://github.com/SYSTRAN/faster-whisper) (large-v3-turbo) on the CPU
- **Thinking:** [Claude Code](https://claude.com/claude-code) in print mode, with **no tools** for normal chat
- **Speaking:** [Kokoro](https://github.com/thewh1teagle/kokoro-onnx) (British voices)
- **Reaching it:** [Tailscale](https://tailscale.com) Serve (tailnet only), optionally Funnel for text-only public access
- **PC control (optional):** Jarvis can *propose* a task; it only runs after you tap **Approve** in the iPhone
  app, and only with the app token over Tailscale.

Works on Linux and Windows, including a dual-boot PC: the iPhone app holds two connections and uses whichever
is online, and the Watch Shortcut finds the live one through a private ntfy.sh status topic.

## Layout

```
server/            server.py (HTTP API), hear/worker.py (speech to text), speak/worker.py (text to speech)
server/config.example.json
linux/             systemd user units + heartbeat script
windows/           installer, heartbeat task, watch-token helper (PowerShell)
ios/JarvisApp/     SwiftUI iPhone app (builds on Linux with xtool, no Mac needed)
```

## API

All requests need `Authorization: Bearer <token>`.

| Route | What it does |
|---|---|
| `POST /api/text` | `{"text": "..."}` → `{"say": "...", "saved": bool}` (`?audio=1` adds a WAV) |
| `POST /api/ask` | audio body (m4a/wav/webm) → NDJSON stream: heard, then each spoken sentence, then done |
| `GET /api/status` | health check |
| `POST /api/voice` | change voice |
| `POST /api/reset` | start a fresh conversation |
| `GET /api/actions`, `POST /api/action/<id>/approve` | PC tasks (app token + tailnet only) |

Built-in guard rails: 5 bad tokens lock an address out for an hour; 20 questions a minute and 300 a day per
token; requests arriving through Funnel can only use the talking routes.

## Setup

### Server (Linux)
1. Put `server/` in `~/jarvis`, create venvs in `hear/` and `speak/` (`faster-whisper`, `kokoro-onnx`,
   `soundfile`), and download the Whisper and Kokoro models.
2. Install and sign in to Claude Code (`claude`).
3. Copy `linux/systemd/*` to `~/.config/systemd/user/`, `linux/jarvis-heartbeat` to `~/.local/bin/`, then
   `systemctl --user enable --now jarvis jarvis-heartbeat.timer`.
4. `tailscale serve --bg --https=443 http://127.0.0.1:4100`

### Server (Windows)
Run `windows/Setup-Jarvis-Windows.ps1` from a folder containing `app\` (the `server/` files plus models).
It installs Python and ffmpeg, makes the venvs, registers a boot-time task and sets up Tailscale Serve.
Then run `Setup-Jarvis-Heartbeat.ps1` if you use the dual-boot Watch Shortcut.

`config.json` is created on first run with a random app token. Copy `config.example.json` for the other fields.
**Never commit `config.json`.**

### iPhone app
Build with [xtool](https://github.com/xtool-org/xtool): `xtool dev build -c release --ipa`, then sign and
install the IPA. **Use [Signulous](https://www.signulous.com) or [iLoader](https://github.com/nab138/iloader)**;
they are the easiest ways to install it:
- **Signulous** (on the iPhone itself, no computer needed): download the IPA in Safari (Tailscale on) so it lands in
  Files, then in Signulous import it, sign it and install.
- **iLoader** (from a computer): plug in the iPhone, sign in with your Apple ID, and drop the IPA onto iLoader.

Set your bundle ID in `xtool.yml` and `Keychain.swift`, and enter each server's address and app token in the app's
Settings.

### Hands-free and voice lock (optional)
- **Wake word:** Settings → Hands-free → *Say "Jarvis" to talk*. Uses Apple's on-device speech recognition, only while
  the app is open on screen. Say "Jarvis", wait for the buzz, then speak; it stops when you go quiet.
- **Voice lock:** install the speaker model once on each server, then enroll from Settings → Voice lock (3 samples).
  ```
  hear/.venv/bin/pip install sherpa-onnx
  curl -L -o hear/speaker-model.onnx https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34.onnx
  ```
  Enrolling is app token + tailnet only (never Funnel or the Watch token). `voiceprint.json` stays on the PC and is
  gitignored. If the lock is on and the model is missing, voice requests are refused rather than let through.
  Tune `speaker_threshold` in `config.json` (default 0.45; each check's score is in `logs/jarvis.log`). Raise it if
  other voices get through, lower it if it rejects you. It is a convenience lock, not strong security.

### Apple Watch Shortcut
1. **Get Contents of URL** `https://ntfy.sh/<your-topic>/raw?poll=1&since=latest` (finds the live PC)
   **Then add an *If* check:** only continue when the result *begins with* `https://` and *contains*
   `.<your-tailnet>.ts.net`; otherwise *Stop*. Without this, anyone who learns your ntfy topic can post a
   fake address and your Watch would send its Bearer token there. Keep the topic long, random and private.
2. **Ask for Input** (Text). Don't use *Dictate Text*; it fails when Siri runs the Shortcut on the Watch.
3. **Get Contents of URL**: POST to the result of step 1, header `Authorization: Bearer <watch token>`,
   JSON body `text` = Provided Input
4. **Get Dictionary Value** `say`, then **Show Result**

Turn on *Show on Apple Watch* and say "Hey Siri, Ask Jarvis".
