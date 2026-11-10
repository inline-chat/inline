---
title: "OpenClaw"
description: "Install the Inline plugin for OpenClaw."
---

## Easy setup

```bash
inline agents setup --target openclaw
```

The command checks the installed OpenClaw version before creating a bot, installs
the matching trusted plugin, restarts the gateway, and only reports ready after a
live Inline probe. If it stops, the error includes the failed phase and retry
command. If Inline is already installed, start the gateway for that profile
before retrying setup. The live probe identifies the existing bot.

## Install

Install the plugin that matches your OpenClaw version:

| OpenClaw                                          | Inline plugin | Install                                                                                     |
| ------------------------------------------------- | ------------- | ------------------------------------------------------------------------------------------- |
| `2026.11.1` and newer                             | `1.0.0-alpha.1`       | `openclaw plugins install npm:@inline-openclaw/inline@1.0.0-alpha.1 --force --accept-capabilities`  |
| `2026.8.2` through `2026.10.x`                    | `0.0.72`      | `openclaw plugins install npm:@inline-openclaw/inline@0.0.72 --force --accept-capabilities` |
| `2026.7.x` (`>=2026.7.1`)                         | `0.0.63`      | `openclaw plugins install @inline-openclaw/inline@0.0.63 --force`                           |
| `2026.6.x` (`>=2026.6.11`, including `2026.6.34`) | `0.0.63`      | `openclaw plugins install @inline-openclaw/inline@0.0.63 --force`                           |

Plugin 1.0 needs OpenClaw `2026.11.1` or newer, and OpenClaw refuses to install
it on an older host. Use the pinned command above to opt into the alpha. The stable npm release is `0.0.72`. Check your version with `openclaw --version`.

`--accept-capabilities` approves the capabilities declared by Inline's trusted
first-party package so the install can't stall on a prompt. OpenClaw 2026.7 and
older don't recognize that flag.

## Configure

Set `channels.inline`:

```yaml
channels:
  inline:
    enabled: true
    token: "<INLINE_BOT_TOKEN>"
```

You may omit `token` and provide `INLINE_TOKEN` to the gateway.

Defaults:

- `dmPolicy: "pairing"`
- `groupPolicy: "open"`
- `requireMention: true`

Configure allowlists for a restricted bot. A mention requirement is not an operator allowlist.

## How it behaves

OpenClaw follows the same rules as Hermes in Inline.

- Only a mention, a reply to the bot, a DM, a command for it, or a thread it follows wakes it. Words never do, its name included.
- A message that starts by mentioning someone else isn't for it, and neither is a reply to someone else, unless it also mentions the bot.
- A thread's first message decides which bots follow. A bot mentioned later answers once without following. `/follow` and `/unfollow` change it, and so does asking the agent.
- Reply threads are Auto or On, per chat, DMs included. Auto answers in the chat and starts a thread when someone asks. On answers each top-level message in a reply thread. Set it with `/threads`, the agent settings, or by asking the agent; On is never bot-wide, so a new chat's first message doesn't get a thread.
- Answers quote only another bot that asked, so the answer reaches it. Its reply back needs no answer, so two bots can't wake each other without end.
- Messages sent while the gateway was down aren't answered after a restart.

## Restart

Restart the gateway:

```bash
openclaw gateway restart
```

List plugins:

```bash
openclaw plugins list
```

Check the Inline channel:

```bash
openclaw channels status --channel inline --probe --json
```

Inspect the plugin:

```bash
openclaw plugins inspect inline --json
```

Open a DM with the bot, complete pairing, and verify it works.

## Update

On OpenClaw `2026.11.1` and newer, check the tracked selection with
`openclaw plugins update inline --dry-run`. An exact install keeps its version
pin. To switch that install to the latest stable release, use
`openclaw plugins update @inline-openclaw/inline@latest --accept-capabilities`
as the update command below. Keep the compatible pin on older hosts.

After active turns finish, update the same gateway profile from the host:

```bash
openclaw gateway stop
openclaw plugins update inline --accept-capabilities
openclaw gateway start
openclaw channels status --channel inline --probe --json
```

For a foreground gateway, stop and relaunch the foreground process. For a named
profile, pass `--profile <name>` before each subcommand.

## Checks

- Plugin missing: check `openclaw plugins list` and the gateway's install environment.
- Token missing: set `channels.inline.token` or `INLINE_TOKEN`.
- DM ignored: complete pairing or check the sender allowlist.
- Group ignored: check group policy, sender policy, and the mention. A thread the bot only wrote in isn't one it follows; use `/follow`.
- No reply: check provider sign-in and gateway errors.

---

[Plugin source and configuration](https://github.com/inline-chat/inline/tree/main/plugins/openclaw)

## Source

- [Plugin source and configuration](https://github.com/inline-chat/inline/tree/main/plugins/openclaw)
