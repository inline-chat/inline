# Create a Bot

Source: https://inline.chat/docs/creating-a-bot

## macOS app

1. Open **Inline → Settings → Bots**.
2. Enter a name and a username ending in `bot`.
3. Select **Create Bot**.
4. Copy the new token and store it securely.

## CLI

Sign in:

```bash
inline auth login
```

Create the bot:

```bash
inline bots create --name "My Inline Bot" --username myinlinebot
```

Use the token with [OpenClaw](https://inline.chat/docs/openclaw), [Hermes Agent](https://inline.chat/docs/hermes), or your own [Bot API](https://inline.chat/docs/bot-api) integration.
