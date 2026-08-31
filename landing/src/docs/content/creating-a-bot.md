---
title: "Create a Bot"
description: "Create a bot identity, retrieve its token, and verify authentication."
---

A bot has its own identity and token. Creating it does not start a program that responds to messages; connect the token to an integration or run your own code.

For Codex, Claude, OpenCode, Amp, OpenClaw, or Hermes, [agent setup](/docs/agents) can create or reuse a bot for you. The steps below are for manual setup.

## macOS App

1. Open **Inline → Settings → Bots**.
2. Enter a name and a username ending in `bot`.
3. Select **Create Bot**.
4. Copy the new token and store it securely.

## CLI

[Install the CLI](/docs/cli), then sign in:

```bash
inline login
```

Create the bot:

```bash
inline bots create --name "My Inline Bot" --username myinlinebot
```

The table output hides the token. Replace `123` below with the bot's user ID from the result to reveal it. **This command prints a secret**; run it in a private terminal, not a shared log or recording:

```bash
inline bots reveal-token --bot-user-id 123
```

Find an existing bot's ID with `inline bots list`.

## Verify and Connect

Provide the token as `INLINE_BOT_TOKEN` in your process environment or secret manager. Do not commit it, include it in a URL you share, or paste it into a support report.

```bash
curl -sS "https://api.inline.chat/bot/getMe" \
  -H "Authorization: Bearer ${INLINE_BOT_TOKEN}"
```

An `ok: true` response identifies the bot. Your personal CLI login is not a Bot API credential.

Use the token with [OpenClaw](/docs/openclaw), [Hermes Agent](/docs/hermes), or the [Bot API quickstart](/docs/bot-api#first-message). Before using a team chat, test in a direct message with the bot.
