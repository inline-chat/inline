---
title: "Create a Bot"
description: "Create or reveal an Inline bot token."
---

## macOS App

1. Open **Inline → Settings → Bots**.
2. Enter a name and a username ending in `bot`.
3. Select **Create Bot**.
4. Copy the new token and store it securely.

## CLI

Sign in:

```bash
inline login
```

Create the bot:

```bash
inline bots create --name "My Inline Bot" --username myinlinebot
```

Use the token with [OpenClaw](/docs/openclaw), [Hermes Agent](/docs/hermes), or your own [Bot API](/docs/bot-api) integration.
