---
title: "Create a Bot"
description: "Create a bot and retrieve its token."
---

Bots have a name, username and a token to give them life through our API, plugins or Bot client SDK.
For connecting your agents, you need a bot. However, our CLI's `inline agents setup` or macOS `Set Up an Agent` flows do it automatically.

## Inline for Mac

1. Open **Inline → Settings → Bots**.
2. Enter a name and a username ending in `bot`.
3. Select **Create Bot**.
4. Copy the token.

## CLI

Create the bot:

```bash
inline bots create --name "My Inline Bot" --username myinlinebot
```

List existing bots:

```bash
inline bots list
```

Reveal a bot token. This prints a secret:

```bash
inline bots reveal-token --bot-user-id 123
```

## Verify

Set `INLINE_BOT_TOKEN`, then call `getMe`:

```bash
curl -sS "https://api.inline.chat/bot/getMe" \
  -H "Authorization: Bearer ${INLINE_BOT_TOKEN}"
```

---

[Bot API](/docs/bot-api) · [OpenClaw](/docs/openclaw) · [Hermes Agent](/docs/hermes) · [Set Up an Agent](/docs/agents)
