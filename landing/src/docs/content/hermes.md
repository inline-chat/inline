---
title: "Hermes Agent"
description: "Install Inline for Hermes Agent."
---

## Easy setup

```bash
inline agents setup --target hermes
```

Note: This is brittle given all the moving parts and constant releases. If it fails, proceed with manual setup or ask your agent to follow this guide and set it up for you. It's easier if you install the Inline CLI first.

## Install Manually

Install the adapter (plugin):

```bash
npm install -g @inline-chat/hermes-agent-adapter
```

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
inline-hermes doctor
```

Probe Inline connectivity:

```bash
hermes inline status
```

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
