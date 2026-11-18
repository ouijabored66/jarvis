# Lumen Voice

Source: https://github.com/ouijabored66/lumen-voice

A free iPhone and Apple Watch voice app. You talk on the device. Lumen answers with one of three connections:

- **Your API key.** One key, stored in the iOS Keychain. The app detects Grok (`xai-`), Claude (`sk-ant-`), Gemini (`AIza`), Groq (`gsk_`), or OpenRouter (`sk-or-`) and shows "Connected to …". The screen shows only the last four characters. A plain OpenAI key (`sk-` that is not `sk-ant-` or `sk-or-`) is not detected. For that, use Cloud / custom provider and the provider's chat URL.
- **Your own server.** `python3 desktop/server.py` forwards text. The provider key stays on that computer, or text goes to Ollama. The default port is **8787**. Set `LUMEN_PORT` to use another port. `python3 server/server.py` is the older text server on port **4100** (it also reads `LUMEN_PORT`).
- **Cloud / custom provider.** A local or cloud chat address. Auto tries the local URL first. A cloud address uses the same one key.

Speech uses Apple's on-device Speech and `AVSpeechSynthesizer`. Recordings stay in memory and are discarded. Nothing in this repo uploads dictation or plays a WAV from a server.

There is no subscription.

## Install Lumen on your iPhone (easy way)

This puts Lumen on the iPhone. It does not put it on the Apple Watch. The Watch needs the later section, [Installing the Apple Watch app from Linux](#installing-the-apple-watch-app-from-linux-free-apple-id).

You need a computer (Windows or Mac), a cable, and a free Apple ID. A spare Apple ID is a good idea, so you are not typing the password for your main Apple ID into the install tool.

The easiest tool is [Sideloadly](https://sideloadly.io) for Windows or Mac. [AltStore](https://altstore.io) and [SideStore](https://sidestore.io) can also install the same file. The steps below are Sideloadly's.

1. Download [LumenVoice-1.6-unsigned.ipa](https://github.com/ouijabored66/lumen-voice/releases/download/v1.6/LumenVoice-1.6-unsigned.ipa). That file is not signed yet. Sideloadly signs it with your Apple ID.
2. Download Sideloadly from [sideloadly.io](https://sideloadly.io) and install it.
3. Plug the iPhone into the computer. If the phone asks you to trust this computer, tap Trust and enter the phone passcode. Sideloadly should then show the phone. If it does not, install Apple's iTunes from Apple's website (not the Microsoft Store app), open iTunes once with the phone plugged in, and tap Trust again.
4. Drag `LumenVoice-1.6-unsigned.ipa` onto the Sideloadly window.
5. Type the Apple ID, then start the install. Sideloadly asks for the Apple ID password, and for the two-factor code if Apple sends one. Wait until the Lumen Voice icon is on the Home Screen.
6. On the iPhone, open Settings, then General, then VPN & Device Management (Sideloadly also calls this Profiles/VPN & Device Management). Tap the Apple ID email you just used, then tap Trust.
7. Still in Settings, open Privacy & Security, scroll to Developer Mode, and turn the switch on. The phone asks you to restart. After it turns back on, confirm Developer Mode (tap Enable and enter the passcode). You may not see Developer Mode until the install in step 5 has finished.
8. Open Lumen Voice.

A free Apple ID only keeps the app working for 7 days. Before it stops opening, plug the phone in and install the same file again with the same Apple ID. Sideloadly also has an option to refresh the app for you. Leave that on only if the computer can stay on and the phone is plugged in, or on the same Wi-Fi with Sideloadly's Wi-Fi sideloading turned on.

A free Apple ID can have 3 sideloaded apps on the phone at the same time. If you see "maximum number of installed apps using a free developer profile", delete one sideloaded app and try again. Apple also lets a free account create only 10 App IDs every 7 days. If you hit that, wait a few days or use another Apple ID.

### First launch

The first screen says "How should Lumen think?"

- To try it with no key and no server: close that screen, tap the sliders button at the top, and turn on Demo Mode under "Try it without a server". You get sample replies. Nothing is sent off the phone.
- To use your own key: tap Use your API key, paste a Grok, Claude, Gemini, Groq, or OpenRouter key, and tap Save and connect. When it works you see "Connected to …", and the screen shows only the last four characters of the key.

## Desktop server

```bash
python3 desktop/server.py
```

On first run it writes `desktop/config.json` (gitignored) with a random token and prints that token plus the LAN URL. In the iPhone app choose **Run your own server** and enter them.

The listen port is `8787` unless `desktop/config.json` or the environment says otherwise:

```bash
LUMEN_PORT=8787 LUMEN_PROVIDER_KEY=… python3 desktop/server.py
```

`LUMEN_PROVIDER_KEY` is the assistant key on that computer (`xai-` Grok, `sk-ant-` Claude, `AIza` Gemini, `gsk_` Groq, `sk-or-` OpenRouter). The same value can be `provider_key` inside `desktop/config.json`. With no key, text goes to Ollama at `http://127.0.0.1:11434` (model `llama3.2`, or `LUMEN_OLLAMA_MODEL`).

On the same network, publish the server with Tailscale Serve so the phone uses HTTPS:

```bash
tailscale serve --bg --https=443 http://127.0.0.1:8787
```

Use the port you actually started (`LUMEN_PORT`, otherwise 8787). Don't put the server on the open internet without HTTPS.

`server/server.py` listens on `127.0.0.1:4100` and speaks the same text API. It does not take audio. The unit `linux/systemd/lumen.service` is that older server (it expects `~/lumen/server.py`). The desktop server unit is `linux/systemd/lumen-server.service`.

### PC task approvals

Approve and Deny work only when the iPhone is in **Run your own server** mode and is talking to `desktop/server.py`. They do not run in API key mode or Cloud / custom provider mode.

The server proposes a shell command and does not run it. Nothing runs until you tap Approve. Deny drops it. A pending command expires after about 10 minutes. Approval still goes through the phone, including when you tap Approve on the Watch. After it runs, the reply is a short spoken summary with the key numbers. The full output stays under Details. A command that prints output and then exits with an error still counts as done, with a note.

On Linux the command runs in the POSIX shell (`df -h` for disk space). On Windows it runs in PowerShell, not in cmd (`Get-PSDrive -PSProvider FileSystem` for disk space). The server tells the assistant which shell this computer uses. Status responses send `X-Server-OS: linux` or `X-Server-OS: windows`, and the app lights that system.

### Phone without the Tailscale app

Tailscale Funnel gives the phone a public HTTPS address, so the phone does not need the Tailscale app:

```bash
tailscale funnel --bg --https=8443 http://127.0.0.1:8787
```

That address is on the open internet. The token is the only protection. Turn it off with:

```bash
tailscale funnel --https=8443 off
```

### Keep the desktop server running (Linux)

Clone the repo to `~/lumen-voice` (the `main` branch). Then:

```bash
mkdir -p ~/.config/systemd/user
cp linux/systemd/lumen-server.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now lumen-server.service
```

`ExecStart` is `/usr/bin/python3 %h/lumen-voice/desktop/server.py` and `Restart=on-failure`. `loginctl enable-linger "$USER"` keeps it up when you are logged out. Put `LUMEN_PORT` and `LUMEN_PROVIDER_KEY` in `~/.config/environment.d/lumen.conf` or in `desktop/config.json` if you do not want them only in the shell that started the process.

## Windows

This runs the small server on your Windows computer so the iPhone can use it. The phone and the computer need to be on the same Wi-Fi. Leave the server window open, or the phone cannot reach it.

1. Open PowerShell. Click Start, type `PowerShell`, and click Windows PowerShell. A blue window opens.
2. Install Python. Open [python.org/downloads/windows](https://www.python.org/downloads/windows/) and download Python 3.12. Run the installer. On the first screen, check **Add python.exe to PATH**, then click **Install Now**. When it finishes, close the blue window, open PowerShell again, type `python --version`, and press Enter. You should see `Python 3.12`. If it says Python was not found, the PATH box was not checked. Run the installer again and check it.
3. Download Lumen. Open [github.com/ouijabored66/lumen-voice](https://github.com/ouijabored66/lumen-voice). Click the green **Code** button, then **Download ZIP**. In your Downloads folder, right-click the zip, click **Extract All**, then **Extract**. You get a folder named `lumen-voice-main`.
4. Start the server. In the blue window, type `cd` and a space. Drag the `lumen-voice-main` folder onto the window, then press Enter. Type `python desktop\server.py` and press Enter. Leave this window open. Closing it stops the server.
5. Read the address and the token. The window prints `Lumen desktop server`, then lines like this:

   ```text
   In the iPhone app choose Run your own server and enter:

     URL    http://…:8787
     Token  (a long random string)
   ```

   The numbers after `http://` are your computer's address. Use a line that does not say `127.0.0.1`. The token is the line that starts with `Token`. The first run also saves both in `desktop\config.json`, inside the folder you unzipped.
6. Type them into the iPhone. Open Lumen. On the screen that says "How should Lumen think?", tap **Run your own server**. You will see **Your server**, a box that says `https://…`, and **Server token**. Paste the URL into the box and the token into Server token. Tap **Save and connect**. If you already closed that screen, tap the sliders button at the top. The screen title is Settings. Set **Connection** to **Run your own server**, fill in the same two lines, and tap **Save and connect**. When it works, that row says Online or In use.
7. Allow the firewall prompt. Windows may show a window that says it blocked some features of Python. Check **Private networks**. Leave **Public networks** unchecked. Click **Allow access**. If you click Cancel, the phone on your Wi-Fi cannot connect.
8. Keep it running when you sign in. You only need to do this after the window has printed a URL once. Click Start, type `Task Scheduler`, and open it. Click **Create Basic Task**. Name it `Lumen Desktop Server` and click Next. Choose **When I log on**, then Next. Choose **Start a program**, then Next. In Program/script, click Browse and choose `python.exe` (the same Python from step 2). In Add arguments, type `desktop\server.py`. In Start in, paste the path of the `lumen-voice-main` folder. Click Next, then Finish. After the next sign-in you will not see the blue window. The address and token stay the ones already printed.

With no provider key, the server sends text to Ollama on this PC if Ollama is already running. Adding a key is in Advanced, below.

### Advanced

The default port is **8787**. To use another port, or to give the server a provider key, set them in the same PowerShell window before you start the server. A key set only in that window is forgotten when you close it. For the sign-in task, put `port` and `provider_key` in `desktop\config.json` instead.

```powershell
$env:LUMEN_PORT = "8787"
$env:LUMEN_PROVIDER_KEY = "paste-the-provider-key"
python desktop\server.py
```

`LUMEN_PROVIDER_KEY` is `xai-` Grok, `sk-ant-` Claude, `AIza` Gemini, `gsk_` Groq, or `sk-or-` OpenRouter.

The same sign-in task can be registered from PowerShell. Environment variables from one window are not copied into the task.

```powershell
$repo = (Resolve-Path .).Path
$py = (Get-Command python).Source
$action = New-ScheduledTaskAction -Execute $py -Argument "desktop\server.py" -WorkingDirectory $repo
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
Register-ScheduledTask -TaskName "Lumen Desktop Server" -Action $action -Trigger $trigger -Force
```

`windows/Setup-Lumen-Windows.ps1` does not start `desktop/server.py`. It installs the older text server (`server/server.py`, port 4100). It looks for an `app` folder with `server.py` next to the script, installs Python 3.12 with winget if it is missing, copies that folder to `%LOCALAPPDATA%\Lumen`, and registers a scheduled task named "Lumen Server" that starts at startup and at sign-in. If Tailscale is installed it also runs `tailscale serve` on port 443. Windows blocks scripts by default. This command applies Bypass only to that process:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\Setup-Lumen-Windows.ps1
```

Remove that task and turn Serve off with `-Uninstall`. The copied files stay in `%LOCALAPPDATA%\Lumen`.

Tailscale Serve keeps the desktop server on your tailnet. The phone needs the Tailscale app:

```powershell
tailscale serve --bg --https=443 http://127.0.0.1:8787
```

Funnel is for a phone that does not have the Tailscale app. That address is public and protected only by the token:

```powershell
tailscale funnel --bg --https=8443 http://127.0.0.1:8787
tailscale funnel --https=8443 off
```

Approved PC commands on Windows run in PowerShell (`powershell.exe -NoProfile -NonInteractive -Command`), not in cmd and not in bash. A command such as `Get-PSDrive -PSProvider FileSystem` or `Get-ChildItem` fits. `df` does not. The app shows Windows when the server sends `X-Server-OS: windows`.

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

When a task needs a yes or no, the Watch shows Approve and Deny. That only works in Run your own server mode, with `desktop/server.py` running. The tap goes to the iPhone, which talks to that computer. If the iPhone is out of reach, the request stays waiting. API key mode and Cloud / custom provider mode do not propose or run PC commands.

### Sideload with a free Apple ID

GitHub Actions builds **LumenVoice-1.6-unsigned.ipa** (the iPhone app with the Watch app inside). A free Apple ID can only hold a few App IDs, so install Lumen Voice inside one container:

1. Install [SideStore](https://sidestore.io) with your free Apple ID.
2. Install [LiveContainer](https://github.com/LiveContainer/LiveContainer) through SideStore.
3. Download [LumenVoice-1.6-unsigned.ipa](https://github.com/ouijabored66/lumen-voice/releases/download/v1.6/LumenVoice-1.6-unsigned.ipa) from the v1.6 release and import it into LiveContainer.

LiveContainer cannot install a watch app. To put Lumen on the watch, install it as a normal app. See [Installing the Apple Watch app from Linux (free Apple ID)](#installing-the-apple-watch-app-from-linux-free-apple-id).

The workflow is `.github/workflows/build-ipa.yml`. It runs on pushes to `lumen-voice` and on pull requests into `watch-companion`.

**Demo Mode** (Settings, top) runs the app with sample replies and no server, so you can try it before you add a key.

### Hands-free

Settings → Hands-free → *Say "Lumen" to talk*. Recognition stays on the iPhone, and only while the app is open on screen. Say "Lumen", wait for the buzz, then speak.

Siri: "Hey Siri, Ask Lumen".

## Installing the Apple Watch app from Linux (free Apple ID)

A free Apple ID can sideload 3 apps on a device and register 10 App IDs every 7 days. A watch app cannot be installed from inside LiveContainer, so Lumen has to be installed as a normal app. A free signature expires after 7 days.

There is no helper script in this repo. The commands below are the published pymobiledevice3 commands. Stock xtool 1.24 still does not install the embedded watch app by itself.

### Problems and fixes

1. **xtool crashes at "Provisioning 33%"** with a NIO `epoll_ctl` error, `Operation not permitted`. It is waiting for a yes/no prompt (revoke an existing development certificate) and has no terminal. Run it in a pty and answer the prompt:

   ```bash
   script -qfec "xtool install --usb LumenVoice-1.6-unsigned.ipa" /tmp/xtool.log
   ```

2. **Apple returns 409** `no current iOS devices on this team`. The phone was just registered. Wait a few seconds and retry.

3. **`InvalidCompanionAppBundleIdentifier` / `WatchKitAppBundleIDNotPrefixed`.** xtool prefixes the iPhone bundle ID (`XTL-<TEAM>.`) and leaves the watch app unprefixed. Set the watch app's `WKCompanionAppBundleIdentifier` to the prefixed iPhone bundle ID, `XTL-<TEAM>.ouijabored66.lumenvoice`.

4. **"Maximum number of installed apps using a free developer profile".** Delete one sideloaded app, then remove its leftover provisioning profiles:

   ```bash
   ideviceprovision list
   ideviceprovision remove <uuid>
   ```

5. **The watch Install button does nothing.** xtool 1.24 does not provision or sign `Watch/*.app`, does not register the paired watch as a device, and signs every bundle with the main app's entitlements. Build from the open watchOS work at [xtool pull request 350](https://github.com/xtool-org/xtool/pull/350). That change adds `xtool dev sign-watch` (a profile that lists registered watches, and it refuses to revoke a certificate automatically) and a Python helper under `tools/watchos` that installs through the paired iPhone's companion proxy (`com.apple.streaming_zip_conduit`). For this app's embedded watch bundle, the patch has to provision `Watch/*.app` and its plug-ins, register the paired watch as a device, and sign each bundle with its own profile and entitlements. The pull request is the source to build that from. It is experimental: `xtool install` still does not install a companion watch app on its own, and the helper wants exactly one watch already listed by the phone.

6. **Developer Mode is missing on the watch.** watchOS hides it until a computer pairs with the watch. Install pymobiledevice3 (`pip install pymobiledevice3`). Plug in the iPhone and tap Trust. `pymobiledevice3 amfi reveal-developer-mode` only shows the switch under Settings, Privacy & Security. It does not turn Developer Mode on. Turn the switch on, let the watch restart, and confirm. If the watch has no passcode, `pymobiledevice3 amfi enable-developer-mode` requests that restart and can confirm the prompt. `pymobiledevice3 amfi developer-mode-status` prints true or false. Unlock the watch and tap Trust when it asks. The upstream helper's first pairing was not fully validated, so trust the computer on the watch before you install.

7. Install the signed watch app with the helper from that pull request. Do not invent a second installer.

### Re-sign every 7 days

1. Start from the unsigned IPA on the v1.6 release (`LumenVoice-1.6-unsigned.ipa`).
2. If Developer Mode is hidden, reveal it with `pymobiledevice3 amfi reveal-developer-mode`, turn it on, and confirm after restart.
3. Install the iPhone app in a pty and answer the certificate prompt: `script -qfec "xtool install --usb LumenVoice-1.6-unsigned.ipa" /tmp/xtool.log`.
4. If Apple returns 409, wait a few seconds and run the install again.
5. Set `WKCompanionAppBundleIdentifier` to `XTL-<TEAM>.ouijabored66.lumenvoice`.
6. If the free profile is full, delete one sideloaded app and remove its profiles with `ideviceprovision`.
7. Sign with a build of xtool from [pull request 350](https://github.com/xtool-org/xtool/pull/350) so `Watch/*.app`, its plug-ins, and the paired watch are covered, each bundle with its own profile and entitlements.
8. Install the signed watch app with that pull request's `tools/watchos` helper, after the watch is already trusted.

### Talk button

Tap Talk to record. Tap again to send.
