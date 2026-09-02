---
title: "OpenClaw"
description: "Configure the official Inline OpenClaw plugin."
---

Add Inline as an OpenClaw channel. The current plugin targets the OpenClaw 2026.8 line from 2026.8.2. You also need a configured model provider and an [Inline bot token](/docs/creating-a-bot).

For guided setup, use `inline agents setup --target openclaw`. The manual path follows.

## Install

Choose the plugin version for your OpenClaw release line:

- OpenClaw `2026.8.x` (`>=2026.8.2`): Inline plugin `0.0.64` — `openclaw plugins install --force @inline-openclaw/inline@0.0.64`
- OpenClaw `2026.7.x`: Inline plugin `0.0.63` — `openclaw plugins install --force @inline-openclaw/inline@0.0.63`
- OpenClaw `2026.6.x` (`>=2026.6.11`, including extended-stable `2026.6.34`): Inline plugin `0.0.63` — `openclaw plugins install --force @inline-openclaw/inline@0.0.63`

The unversioned install follows the newest supported OpenClaw line:

```bash
openclaw plugins install @inline-openclaw/inline
```

## Configure

Set `channels.inline` in your OpenClaw configuration. The example token is a placeholder; keep the real token out of source control and shared logs. You may leave `token` unset and provide `INLINE_TOKEN` in the gateway environment instead.

```yaml
channels:
  inline:
    enabled: true
    token: "<INLINE_BOT_TOKEN>"
```

| Default | Meaning |
| --- | --- |
| `dmPolicy: "pairing"` | DM users request access through pairing. |
| `groupPolicy: "open"` | The integration does not restrict group chats to an allowlist. |
| `requireMention: true` | Group messages require a bot mention by default. Following and reply-thread settings can change activation. |

Review these defaults before adding the bot to shared chats. For a restricted bot, configure the user/group allowlists in the [access policy reference](https://github.com/inline-chat/inline/tree/main/openclaw#who-can-talk-to-the-bot). A mention gate is not an operator allowlist.

## Run

```bash
openclaw gateway run
```

Keep this foreground process running, or use your existing gateway service. Inspect the plugin and channel:

```bash
openclaw plugins list
```

```bash
openclaw channels status
```

```bash
openclaw plugins inspect inline --json
```

Open a DM with the bot, complete pairing if requested, and ask for a short reply. Verify the final response in Inline. “Configured” or “running” alone does not verify the model provider or message delivery.

## Update

```bash
openclaw plugins install --force @inline-openclaw/inline@latest
```

This replaces the installed plugin package. Restart the gateway after updating; restarting can interrupt active work:

```bash
openclaw gateway restart
```

Recheck the plugin version and channel status.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Plugin `inline` not found | Check `openclaw plugins list` and install the package in the same OpenClaw environment as the gateway. |
| Channel reports no token | Provide the token through `channels.inline.token` or the gateway's `INLINE_TOKEN` environment. |
| Bot ignores a DM | Complete pairing or check the configured sender allowlist. |
| Bot ignores a group message | Check group policy, sender policy, and an explicit mention. |
| Plugin runs but no reply arrives | Confirm provider sign-in and send a small DM test; inspect the gateway's error summary without sharing credentials. |

[Plugin source and reference](https://github.com/inline-chat/inline/tree/main/openclaw)
