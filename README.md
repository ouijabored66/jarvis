# Lumen Voice

Source: https://github.com/ouijabored66/lumen-voice

A free iPhone and Apple Watch voice app. You talk on the device. Lumen answers with one of three connections:

- **Your API key.** One key, stored in the iOS Keychain. The app detects Grok, Claude, Gemini, Groq, or OpenRouter and shows "Connected to …". The screen shows only the last four characters.
- **Your own server.** `python3 desktop/server.py` forwards text. The provider key stays on that computer, or text goes to Ollama. `python3 server/server.py` is the same kind of text server on port 4100.
- **Cloud / custom provider.** A local or cloud chat address. Auto tries the local URL first. A cloud address uses the same one key.

Speech uses Apple's on-device Speech and `AVSpeechSynthesizer`. Recordings stay in memory and are discarded. Nothing in this repo uploads dictation or plays a WAV from a server.

There is no subscription.

## Desktop server

```bash
python3 desktop/server.py
```

On first run it writes `desktop/config.json` (gitignored) with a random token and prints that token plus the LAN URL. In the iPhone app choose **Run your own server** and enter them.

```bash
LUMEN_PROVIDER_KEY=… python3 desktop/server.py
```

`xai-` is Grok, `sk-ant-` Claude, `AIza` Gemini, `gsk_` Groq, and `sk-or-` is OpenRouter. With no key, text goes to Ollama at `http://127.0.0.1:11434` (model `llama3.2`, or `LUMEN_OLLAMA_MODEL`).

Away from home, publish the server with Tailscale (`tailscale serve --bg --https=443 http://127.0.0.1:8787`) or another HTTPS address and use that URL in the app. Don't put it on the open internet without HTTPS.

`server/server.py` listens on `127.0.0.1:4100` and speaks the same text API. It does not take audio.

## iPhone and Watch

Bundle IDs:

- `ouijabored66.lumenvoice`
- `ouijabored66.lumenvoice.watchkitapp`

Marketing version **1.6**.

The Watch app sends text to the iPhone, which holds the key. Replies are spoken on the device.

### Sideload with a free Apple ID

GitHub Actions builds **LumenVoice-1.6-unsigned.ipa** (the iPhone app with the Watch app inside). A free Apple ID can only hold a few App IDs, so install Lumen Voice inside one container:

1. Install [SideStore](https://sidestore.io) with your free Apple ID.
2. Install [LiveContainer](https://github.com/LiveContainer/LiveContainer) through SideStore.
3. Download `LumenVoice-1.6-unsigned.ipa` from the workflow run and import it into LiveContainer.

The workflow is `.github/workflows/build-ipa.yml`. It runs on pushes to `lumen-voice` and on pull requests into `watch-companion`.

**Demo Mode** (Settings, top) runs the app with sample replies and no server, so you can try it before you add a key.

### Hands-free

Settings → Hands-free → *Say "Lumen" to talk*. Recognition stays on the iPhone, and only while the app is open on screen. Say "Lumen", wait for the buzz, then speak.

Siri: "Hey Siri, Ask Lumen".
