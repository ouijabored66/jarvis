# Apple Watch

The built-in watchOS companion that used to live in this repo is retired. It was fully built, but free
Apple provisioning profiles never cover an embedded Watch app, so it could not be installed without
the paid Apple Developer Program. The watch route now is an **SSH Shortcut on the watch**, a small
always-on relay machine as the front door, and a pair of wrappers on the desktop that give an API
"hands" inside a fixed cage.

## What you need

**Two always-on computers.** This design needs two machines that stay on:

1. **A front door** — a small always-on computer (here, a handheld PC). The watch Shortcut SSHes
   into it. It holds no API keys and runs no house commands itself; it relays each request to the
   desktop and speaks back whatever the desktop answers.
2. **The desktop** — the machine that holds the API key, the wrappers below, and the smart-home
   (Alexa) helper. Here it dual-boots Linux and Windows, with a wrapper build on each side;
   whichever OS is awake takes the relayed request.

Plus: an Apple Watch and iPhone (for the Shortcut), a Tailscale network joining the watch's phone
and both machines (the Shortcut reaches the front door by its MagicDNS name), and a Meta Model API
key from [dev.meta.ai](https://dev.meta.ai).

## Part 1 — The Shortcut (the watch route)

Build this once in the Shortcuts app on iPhone, and enable **Show on Apple Watch**:

1. Add action **Dictate Text**.
2. Add action **Run Script over SSH** and fill it in:
   - Host: the front door's Tailscale MagicDNS name; Port: 22; User: your user on the front door.
   - Authentication: **SSH Key** (not password). The action generates its own key — copy its
     **public** key and add it to the front door's `~/.ssh/authorized_keys` before the first run.
   - Script: `~/bin/muse-watch-do "`*Dictated Text*`"` — type the quotes, then insert the
     **Dictated Text** variable between them (do not type the words by hand).
3. Add action **Speak Text**, with the SSH step's result as its input.

Then just run it from the watch and talk: a question ("what is the capital of Louisiana"), a light
("turn off the living room lights"), the thermostat ("set the thermostat to heat, 72 degrees"), or
"computer status".

Notes:

- The Shortcut itself holds **no API key**. Keys live only on the desktop (Part 2); the watch is
  just a microphone with an SSH client.
- The model behind the API is **stateless** — no memory between questions. The only "memory" it
  ever sees is a short brief the wrappers attach to answer calls (Part 2).

## Part 2 — What we built (the hands)

### Key storage

- The Meta API key lives ONLY in `~/.config/model-api/key` (folder mode 700, file mode 600) on the
  desktop — once per OS side.
- `~/bin/set-model-api-key` prompts for the key with hidden input and writes that file. The key is
  never typed into a chat, a command line, or a script.
- **Resetting a key revokes the old one everywhere.** If the key is reset at dev.meta.ai, re-run
  `set-model-api-key` on BOTH desktop OS sides, or the wrappers fail with 401 errors.
- An optional `~/.config/model-api/brief.txt` sits beside it: a short plain-text brief about the
  user (name, town, work, house layout, answer style). The wrappers attach it — plus the current
  date and time — to question-answering calls only, so the stateless model answers like it knows
  the house. It is a snapshot, not a sync, and it is one-way: the model can read it, never write
  back.

### muse-watch-ask — plain Q&A

`~/bin/muse-watch-ask "<question>"` POSTs to `https://api.meta.ai/v1/chat/completions` with the
bearer key, model `muse-spark-1.3`, a "brief spoken sentences" instruction, the brief if present,
and the current date/time, and prints `choices[0].message.content`.

### muse-watch-do — routed actions inside a cage

`~/bin/muse-watch-do [--dry-run] "<request>"` makes ONE API call whose only job is routing. The
model must reply with a strict JSON intent from a fixed allowlist — it chooses; it can never
generate a command:

```json
{"action": "lights"|"thermostat"|"computer_status"|"answer",
 "state": "on"|"off"|null, "room": "living room"|"kitchen"|"office"|"all"|null,
 "mode": "HEAT"|"COOL"|null, "temp": <int>|null, "answer": "<text>"}
```

Local code then runs ONLY the matching fixed action, through the desktop Alexa helper
(`~/alexa-login/app/alexa.js`, run with `~/alexa-login/node/bin/node`):

- **lights** (room = living room, kitchen, or office): an Echo text command to "Living room Echo" —
  "turn on/off the \<room\> lights". Room "all" + off runs `power lights off` (one batch call
  across all light endpoints); "all" + on runs the three room commands.
- **thermostat**: a spoken mode (HEAT or COOL) is REQUIRED — without one, nothing runs and it asks
  for the mode. Temperature is fenced to 60–85. Two steps, in order: (1) a direct
  `setThermostatMode` action on the thermostat endpoint; proceed only if the reply contains
  SUCCESS; (2) an Echo text command "set the thermostat temperature to \<temp\> degrees". Never a
  combined command, and never a direct `setTargetSetpoint` action (the API rejects it).
- **computer_status**: hostname, uptime, disk free %, and whether the desktop's Claude bridge is
  running, printed as one spoken-style sentence.
- **answer**: prints the model's brief answer (the Q&A path — the one that gets the brief).

Every request is logged — timestamp, request text, routed intent, result; never the key — to
`~/.local/share/muse-watch/actions.log`. `--dry-run` prints the routed intent and executes
nothing.

A Windows mirror, `muse-watch-do.ps1`, implements the same contract on the desktop's Windows
side (same key folder layout, same router JSON, same two-step thermostat), so the route works in
either OS.

### The front-door relay

The front door runs its own tiny `~/bin/muse-watch-do`: a relay, not a router. It tries the
desktop Linux side's `muse-watch-do` first; if that doesn't answer, it calls the Windows side's
`muse-watch-do.ps1` with the request piped over stdin; if neither answers, it reports that the
desktop seems to be off. The front door authenticates to both desktop sides with its own
dedicated SSH key (authorized on both), and the user's Shortcut key is authorized on the front
door only — one Shortcut, one host, every boot state.
