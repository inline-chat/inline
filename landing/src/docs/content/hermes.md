---
title: "Hermes Agent"
description: "Install Inline for Hermes Agent."
---

## Easy setup

```bash
inline agents setup --target hermes
```

The command installs and configures the adapter, restarts the gateway, and only
reports ready after Hermes verifies the credential and the new gateway process.
If a step fails, Inline shows the failed phase and a retry command instead of
reporting the setup as ready.

## Install Manually

Install the adapter (plugin):

```bash
npm install -g @inline-chat/hermes-agent-adapter
```

### Version Match

| Hermes Agent                 | Inline adapter |
| ---------------------------- | -------------- |
| `>=0.17.0` (tested with `0.21.0`) | `0.0.15`       |

Install the plugin onto Hermes:

```bash
inline-hermes install
```

Enable the plugin:

```bash
hermes plugins enable inline-platform
```

Configure the gateway:

```bash
hermes gateway setup
```

Select **Inline**, then create a bot or paste an existing [bot token](/docs/creating-a-bot).

## Verify

Check the installation:

```bash
inline-hermes doctor --json
```

Probe Inline connectivity:

```bash
hermes inline status --json --probe
hermes gateway status
```

The interactive Hermes wizard saves configuration first; restart and the probe
above are the readiness check.

Start the Hermes gateway, message the bot in Inline, and verify a final reply.
Find your bot by entering its username in CMD+K on macOS or the Search tab on iOS.

## Update

You may be able to update your Inline plugin via the `/inline_update` command in your DM with the Hermes agent.

Or update the adapter manually:

```bash
npm install -g @inline-chat/hermes-agent-adapter@latest
inline-hermes install --force
hermes gateway restart
```

---

[Adapter source and reference](https://github.com/inline-chat/inline/tree/main/hermes-agent)
