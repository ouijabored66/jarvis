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

If you ask for something on this computer, the server proposes a shell command and does not run it. Nothing runs until you tap Approve. Deny drops it. A pending command expires after about 10 minutes. Approval still goes through the phone, including when you tap Approve on the Watch. After it runs, the reply is a short spoken summary with the key numbers. The full output stays under Details. A command that prints output and then exits with an error still counts as done, with a note.

## Cloud / custom server troubleshooting

**Won't save the password/key.** On the main API Key screen only Grok, Claude, Gemini, Groq, or OpenRouter keys are accepted. For your own relay, choose Cloud / custom provider, enter the Cloud URL, paste the password into its API key field, and tap Save key. It shows Key saved, then tests the connection. Any non-empty password is sent as Authorization: Bearer.

**The assistant sent an empty reply.** The server took longer than the app waited, the app retried `/api/ask`, and got a voice-clip-style NDJSON answer. The server's `/api/ask` must accept JSON `{"text":"..."}` and return one JSON object `{"say":"..."}` like `/api/text`, and should reuse an identical in-flight question. Newer builds wait up to 120s.

## iPhone and Watch

Bundle IDs:

- `ouijabored66.lumenvoice`
- `ouijabored66.lumenvoice.watchkitapp`

Marketing version **1.6**.

The Watch works on its own once Cloud is set up on the iPhone, even when that app is closed or the phone is away. It needs Wi-Fi or cellular. It records with its microphone. Nearby, that recording goes to the iPhone. On its own, the Watch turns the recording into text, then asks. If the iPhone does not answer in about 5 seconds, the Watch switches to Direct.

Tapping the complication starts that recording and speaks the reply on the Watch. Text chat stays on the screen. The keyboard appears only when you tap the text field.

Replies can take up to about 2 minutes. The Watch stays awake while it shows "Lumen is answering" and retries once if a request fails. Status shows "Via iPhone" or "Direct".

When a task needs a yes or no, the Watch shows Approve and Deny. The tap goes to the iPhone, which talks to your computer. If the iPhone is out of reach, the request stays waiting.

### Sideload with a free Apple ID

GitHub Actions builds **LumenVoice-1.6-unsigned.ipa** (the iPhone app with the Watch app inside). A free Apple ID can only hold a few App IDs, so install Lumen Voice inside one container:

1. Install [SideStore](https://sidestore.io) with your free Apple ID.
2. Install [LiveContainer](https://github.com/LiveContainer/LiveContainer) through SideStore.
3. Download `LumenVoice-1.6-unsigned.ipa` from the workflow run and import it into LiveContainer.

LiveContainer cannot install a watch app. To put Lumen on the watch, install it as a normal app. See [Installing the Apple Watch app from Linux (free Apple ID)](#installing-the-apple-watch-app-from-linux-free-apple-id).

The workflow is `.github/workflows/build-ipa.yml`. It runs on pushes to `lumen-voice` and on pull requests into `watch-companion`.

**Demo Mode** (Settings, top) runs the app with sample replies and no server, so you can try it before you add a key.

### Hands-free

Settings → Hands-free → *Say "Lumen" to talk*. Recognition stays on the iPhone, and only while the app is open on screen. Say "Lumen", wait for the buzz, then speak.

Siri: "Hey Siri, Ask Lumen".

## Installing the Apple Watch app from Linux (free Apple ID)

A free Apple ID can sideload 3 apps on a device and register 10 App IDs every 7 days. A watch app cannot be installed from inside LiveContainer, so Lumen has to be installed as a normal app. A free signature expires after 7 days.

### Problems and fixes

1. **xtool crashes at "Provisioning 33%"** with a NIO `epoll_ctl` error, `Operation not permitted`. It is waiting for a yes/no prompt (revoke an existing development certificate) and has no terminal. Run it in a pty and answer the prompt:

   ```bash
   script -qfec "xtool install --usb <ipa>" /tmp/xtool.log
   ```

2. **Apple returns 409** `no current iOS devices on this team`. The phone was just registered. Wait a few seconds and retry.

3. **`InvalidCompanionAppBundleIdentifier` / `WatchKitAppBundleIDNotPrefixed`.** xtool prefixes the iPhone bundle ID (`XTL-<TEAM>.`) and leaves the watch app unprefixed. Set the watch app's `WKCompanionAppBundleIdentifier` to the prefixed iPhone bundle ID, `XTL-<TEAM>.ouijabored66.lumenvoice`.

4. **"Maximum number of installed apps using a free developer profile".** Delete one sideloaded app, then remove its leftover provisioning profiles:

   ```bash
   ideviceprovision list
   ideviceprovision remove <uuid>
   ```

5. **The watch Install button does nothing.** xtool 1.24 does not provision or sign `Watch/*.app`, does not register the watch as a device, and signs every bundle with the main app's entitlements. Use a patched xtool that provisions `Watch/*.app` and its plug-ins, registers the paired watch as an extra device, and signs each bundle with its own profile and entitlements.

6. **Developer Mode is missing on the watch.** watchOS hides it until a computer pairs with the watch. Use pymobiledevice3 helper scripts (credit [oacevedo's experimental xtool watchOS branch](https://github.com/xtool-org/xtool/pull/350)) to pair: unlock the watch and tap Trust. Turn Developer Mode on, and confirm it after the watch restarts.

7. Install the signed watch app straight onto the watch with the helper's `--install`.

### Re-sign every 7 days

1. Start from the unsigned IPA (`LumenVoice-1.6-unsigned.ipa`, or a fresh build).
2. If Developer Mode is hidden, pair the watch, turn it on, and confirm after restart.
3. Install the iPhone app in a pty and answer the certificate prompt: `script -qfec "xtool install --usb <ipa>" /tmp/xtool.log`.
4. If Apple returns 409, wait a few seconds and run the install again.
5. Set `WKCompanionAppBundleIdentifier` to `XTL-<TEAM>.ouijabored66.lumenvoice`.
6. If the free profile is full, delete one sideloaded app and remove its profiles with `ideviceprovision`.
7. Sign with a patched xtool so `Watch/*.app`, its plug-ins, and the paired watch are covered, each bundle with its own profile and entitlements.
8. Install the signed watch app onto the watch with the helper's `--install`.

### Talk button

Tap Talk to record. Tap again to send.
