---
title: "ChatGPT Dots"
description: "Bridge your ChatGPT Dot into Inline as a personal bot, on your Mac, a Linux server, or in Docker."
---

The Dots bridge gives your ChatGPT Dot a bot in Inline. You talk to the bot
in a DM; the bridge relays the conversation to your Dot's own ChatGPT room
and back. It runs on your machine through the Inline CLI and keeps your
ChatGPT credential in memory only.

The bridge uses ChatGPT's private API, the same one the ChatGPT apps use.
OpenAI can change or block it at any time; this is not an OpenAI product.

## Before you begin

- A ChatGPT account with a Dot. Create it in the ChatGPT app first.
- The [Inline CLI](/docs/cli), signed in to Inline.
- Codex CLI `0.146.0` or later, or the ChatGPT desktop app, signed in with
  the same ChatGPT account:

```bash
codex login
```

On a server without a browser, use `codex login --device-auth`.

## Set up

```bash
inline setup dots
```

Setup checks the Codex login, finds your Dot, creates a bot named after it,
and starts the bridge service (launchd on macOS, a systemd user unit on
Linux). Use `--name` to pick another bot name.

Open the bot's DM in Inline and send a message.

## Remote Linux server or VM

Everything works over SSH; no browser is needed on the server.

```bash
curl -fsSL https://inline.chat/cli/install.sh | sh
inline auth login
codex login --device-auth
inline setup dots
sudo loginctl enable-linger "$USER"
inline bridge status
```

`codex login --device-auth` prints a code to enter on any device. Setup
installs a systemd user service; without `enable-linger` it stops when you
log out, and setup reminds you. Messages sent to the bot while the bridge
is down are delivered when it starts again, and your Dot's replies from
that time are caught up.

## Next to other bridges

The Dots bridge runs inside the same Inline bridge service as Codex,
Claude, OpenCode, and Amp bots on that machine, with its own bot and DM.
Running `inline setup dots` adds it and restarts the service; the other
bots keep their settings. `inline bridge status` lists each one.

## What goes through

Everything that can sync goes both ways by default.

| | Inline → Dot | Dot → Inline |
| --- | --- | --- |
| Text and replies | Yes | Yes |
| Files and photos (up to 20 MiB) | Yes, one per message | Yes, retried if storage is slow |
| Reactions | Yes | Yes |
| Typing | Yes | Yes |
| Read state | Sending marks the Dot's room read | Read marks on your messages |
| Task progress | — | One card, updated in place, with each prompt and final answer under it |
| Confirmations | Approve or Decline buttons | Yes |
| Edits and deletions | Not possible in ChatGPT; the bot tells you | Shown as edits |
| Messages and files you send in ChatGPT | — | Mirrored with your attribution (`/mirror off` to stop) |
| Dot name and avatar | — | The bot follows them, unless you renamed it or set its photo yourself |

- Messages from before setup are not imported.
- Editing a message still waiting to deliver updates its queued text. If an
  earlier attempt already reached ChatGPT, the bridge tells you to send the
  correction as a new message.
- Notices from ChatGPT itself and messages the bridge can't render appear as
  short placeholders, never silently dropped.
- Confirmations that need more than a yes or no say so and point you to
  ChatGPT.
- Only you can use the bot. Other people, and group chats, are ignored.

## Commands

| Command | What it does |
| --- | --- |
| `/status` | Connection, your Dot's name, and any messages waiting to deliver |
| `/mirror on` or `/mirror off` | Show messages you type in ChatGPT |
| `/help` | What the bridge does |

Any other text, including other `/` commands, goes to your Dot as typed.

## Docker

The image bundles the Inline CLI and the Codex CLI, and stores everything in
one volume. It opens no ports. From a checkout of the Inline repository:

```bash
cd cli/packaging/dots
docker compose build
docker compose run --rm dots setup
docker compose up -d
```

`setup` signs you in to Inline and to ChatGPT (device code), then creates the
bot. Check on it with `docker compose run --rm dots status` or `logs`.

## Troubleshooting

- **"Codex is not signed in"** or **"sign-in needed"** in `/status`: run
  `codex login` as the same user the bridge runs as, then
  `inline bridge restart`.
- **"this ChatGPT account has no Dot yet"**: create the Dot in ChatGPT, or
  sign Codex in to the account that has it.
- **"ChatGPT served a browser challenge"**: ChatGPT blocked the request. The
  bridge does not work around this; try again later.
- `inline bridge status`, `inline bridge doctor`, and `inline bridge logs`
  cover the service.

## Privacy

- The ChatGPT token comes from the local Codex app-server for each sign-in
  check and stays in memory. The bridge never reads `~/.codex/auth.json`.
- Local state (message id mapping, cursors, and the text of messages still
  waiting to deliver) lives in the bridge's private folder on your machine.
- Nothing about your ChatGPT account is sent to Inline's servers beyond the
  messages you exchange in the bot DM.

## Source

- [Relay core](https://github.com/inline-chat/inline/tree/main/crates/relay)
- [ChatGPT Dots client and connector](https://github.com/inline-chat/inline/tree/main/crates/dots)
- [CLI integration](https://github.com/inline-chat/inline/blob/main/cli/src/bridge/dots.rs)
- [Docker and Umbrel files](https://github.com/inline-chat/inline/tree/main/cli/packaging/dots)
