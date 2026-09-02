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
command; no failed or partial run is reported as ready.

## Install

Install the compatible plugin for the current OpenClaw line:

```bash
openclaw plugins install @inline-openclaw/inline --force --accept-capabilities
```

### Version Match

| OpenClaw                                          | Inline plugin |
| ------------------------------------------------- | ------------- |
| `2026.8.x` (`>=2026.8.2`)                         | `0.0.65`      |
| `2026.7.x` (`>=2026.7.1`)                         | `0.0.63`      |
| `2026.6.x` (`>=2026.6.11`, including `2026.6.34`) | `0.0.63`      |

Install a matched version with:

```bash
openclaw plugins install @inline-openclaw/inline --force --accept-capabilities
```

On OpenClaw 2026.8, `--accept-capabilities` approves the capabilities declared
by Inline's trusted first-party package so the noninteractive install cannot
stall on a prompt. Older supported hosts do not recognize that flag; install
their matched `0.0.63` package with `--force` only.

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

Ask OpenClaw to update the tracked Inline plugin:

```bash
openclaw plugins update inline --accept-capabilities
```

Restart after active work finishes:

```bash
openclaw gateway restart
```

## Checks

- Plugin missing: check `openclaw plugins list` and the gateway's install environment.
- Token missing: set `channels.inline.token` or `INLINE_TOKEN`.
- DM ignored: complete pairing or check the sender allowlist.
- Group ignored: check group policy, sender policy, and the mention.
- No reply: check provider sign-in and gateway errors.

---

[Plugin source and configuration](https://github.com/inline-chat/inline/tree/main/openclaw)
