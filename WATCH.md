# Apple Watch

The built-in watchOS companion that used to live in this repo is retired. It was fully built, but free
Apple provisioning profiles never cover an embedded Watch app, so it could not be installed without the
paid Apple Developer Program. The watch route now is a third-party app driven by your own API keys,
plus a pair of small wrappers on the desktop that give an API "hands" inside a fixed cage.

## Part 1 — Install AskWatch (the watch route)

1. Get **Ask Watch AI** from the App Store: https://apps.apple.com/us/app/ask-watch-ai/id6757408222
   Install it on the iPhone, then install its Watch companion from the Watch app.
2. **Meta (Muse):** at [dev.meta.ai](https://dev.meta.ai), open your project (Default Project) →
   **API keys** → create a key. The full key is shown once — copy it then. In AskWatch on iPhone, open
   the **Meta** provider and paste the key. With your own key, pick the Meta model it offers (Muse Wonder).
3. **Claude:** create an API key in the Anthropic Console and paste it into AskWatch's **Claude**
   provider the same way.
4. In AskWatch settings, pick the model the watch starts on. To switch brains on the wrist, open the
   model picker in the watch app and choose the other provider. Keys are stored in iCloud Keychain and
   sync to the watch on their own.

Notes:

- The free tier has daily voice-session limits; a one-time **PRO (BYOK)** unlock removes them.
- Each question goes to ONE provider — the one selected. The two APIs don't blend.
- **Resetting a key revokes the old one everywhere.** If you reset the Meta key at dev.meta.ai, paste
  the new key into AskWatch AND re-run `set-model-api-key` on the desktop (Part 2), or both will fail
  with 401 errors.

## Part 2 — What we built on the desktop (the hands)

AskWatch talks to the APIs directly; it cannot run anything on the desktop. These wrappers live on the
desktop (Linux side) and are how an API gets carefully limited "hands" in the house. They also work
from any terminal or SSH session.

### Key storage

- The Meta API key lives ONLY in `~/.config/model-api/key` (folder mode 700, file mode 600).
- `~/bin/set-model-api-key` prompts for the key with hidden input and writes that file. The key is
  never typed into a chat, a command line, or a script.

### muse-watch-ask — plain Q&A

`~/bin/muse-watch-ask "<question>"` POSTs to `https://api.meta.ai/v1/chat/completions` with the bearer
key, model `muse-spark-1.3`, and a "brief spoken sentences" instruction, and prints
`choices[0].message.content`.

### muse-watch-do — routed actions inside a cage

`~/bin/muse-watch-do [--dry-run] "<request>"` makes ONE API call whose only job is routing. The model
must reply with a strict JSON intent from a fixed allowlist — it chooses; it can never generate a
command:

```json
{"action": "lights"|"thermostat"|"computer_status"|"answer",
 "state": "on"|"off"|null, "room": "living room"|"kitchen"|"office"|"all"|null,
 "mode": "HEAT"|"COOL"|null, "temp": <int>|null, "answer": "<text>"}
```

Local code then runs ONLY the matching fixed action, through the desktop Alexa helper
(`~/alexa-login/app/alexa.js`, run with `~/alexa-login/node/bin/node`):

- **lights** (room = living room, kitchen, or office): an Echo text command to "Living room Echo" —
  "turn on/off the \<room\> lights". Room "all" + off runs `power lights off` (one batch call across
  all light endpoints); "all" + on runs the three room commands.
- **thermostat**: a spoken mode (HEAT or COOL) is REQUIRED — without one, nothing runs and it asks for
  the mode. Temperature is fenced to 60–85. Two steps, in order: (1) a direct `setThermostatMode`
  action on the thermostat endpoint; proceed only if the reply contains SUCCESS; (2) an Echo text
  command "set the thermostat temperature to \<temp\> degrees". Never a combined command, and never a
  direct `setTargetSetpoint` action (the API rejects it).
- **computer_status**: hostname, uptime, root disk free %, and whether the
  `claude-remote-control.service` user service is active, printed as one spoken-style sentence.
- **answer**: prints the model's brief answer (the Q&A path).

Every request is logged — timestamp, request text, routed intent, result; never the key — to
`~/.local/share/muse-watch/actions.log`. `--dry-run` prints the routed intent and executes nothing.

### Triggering the hands from the watch

AskWatch can't invoke desktop scripts. The wrist trigger is an SSH Shortcut:

1. **Dictate Text**
2. **Run Script over SSH** — host: your desktop's Tailscale MagicDNS name, port 22, user: your desktop
   username, SSH key auth; script: `~/bin/muse-watch-do "`*Dictated Text*`"`
3. **Speak Text** with the result.

The Shortcut action generates its own SSH key; add its public key to the desktop's
`~/.ssh/authorized_keys` before the first run.
