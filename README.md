# Jarvis

A private, self-hosted voice and text assistant in the style of Tony Stark's AI. You talk to it from an
iPhone app or its Apple Watch app; it runs on your own PC and answers out loud.

> **Apple Watch app: coming soon.** The watchOS companion is built and ready; it just needs the Apple Developer Program enrollment completed before it can be released.

- **Hearing:** [faster-whisper](https://github.com/SYSTRAN/faster-whisper) (large-v3-turbo) on the CPU
- **Thinking:** [Claude Code](https://claude.com/claude-code) in print mode, with **no tools** for normal chat
- **Speaking:** [Kokoro](https://github.com/thewh1teagle/kokoro-onnx) (British voices)
- **Reaching it:** [Tailscale](https://tailscale.com) Serve (tailnet only), optionally Funnel for text-only public access
- **PC control (optional):** Jarvis can *propose* a task; it only runs after you tap **Approve** in the iPhone
  app, and only with the app token over Tailscale.

Works on Linux and Windows, including a dual-boot PC: the iPhone app holds two connections and uses whichever
is online, and passes both to the Watch app.

## Layout

```
server/            server.py (HTTP API), hear/worker.py (speech to text), speak/worker.py (text to speech)
server/config.example.json
linux/             systemd user unit
windows/           installer, watch-token helper (PowerShell)
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
3. Copy `linux/systemd/*` to `~/.config/systemd/user/`, then `systemctl --user enable --now jarvis`.
4. `tailscale serve --bg --https=443 http://127.0.0.1:4100`

### Server (Windows)
Run `windows/Setup-Jarvis-Windows.ps1` from a folder containing `app\` (the `server/` files plus models).
It installs Python and ffmpeg, makes the venvs, registers a boot-time task and sets up Tailscale Serve.

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

### App Store build (iPhone + Apple Watch)
`ios/JarvisVoice.xcodeproj` (generated from `ios/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen))
builds the iPhone app (`com.ouijabored66.jarvisvoice`) with an embedded Apple Watch app
(`com.ouijabored66.jarvisvoice.watchkitcompanion`). The Watch app takes a dictated question, sends it to the same
server with the same token (handed over from the iPhone app), shows and speaks the reply, and keeps a scrollable history.

`.github/workflows/build-ipa.yml` builds it on a macOS runner:
- **With** the repository secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64` (an App Store Connect API key with
  the Admin role, `.p8` base64-encoded) and `APPLE_TEAM_ID` (secret or variable): signed archive with automatic signing,
  App Store export, and upload to App Store Connect (shows up in TestFlight after processing).
- **Without** them: an unsigned `.ipa` (Watch app embedded) attached to the run as an artifact.

**Demo Mode** (Settings, top) runs the whole app with simulated replies and a sample conversation, with no server, so
it can be tried, and reviewed by App Review, without a Jarvis server.

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

## Contributors

- **ouijabored66** — creator and owner
- **Jarvis** — ouijabored66's personal AI agent (Meta Muse). Architecture, build tooling, and upkeep, working alongside Claude Code.
