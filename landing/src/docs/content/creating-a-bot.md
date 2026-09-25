---
title: "Create a Bot"
description: "Create a bot identity, retrieve its token, and verify Bot API access."
---

A bot is an Inline identity that your integration controls through an API token. Create one when you are building a custom integration or configuring a plugin that asks for a bot token.

This guide takes you from a signed-in Inline account to a successful Bot API `getMe` response. Choose either the [Mac](#inline-for-mac) or [CLI](#cli) procedure, then [verify the token](#verify).

If you are connecting an existing agent, start with [Set Up an Agent](/docs/agents). The `inline agents setup` command and the Mac setup flow create or select a bot for you. For provider-specific instructions, see [OpenClaw](/docs/openclaw) or [Hermes Agent](/docs/hermes).

## About Bots

A bot has three parts:

| Part | Purpose |
| --- | --- |
| Name | The display name people see in conversations. |
| Username | The public handle people use to find the bot. Choose an available username ending in `bot`, such as `myinlinebot`. |
| Token | The credential your program uses to act as the bot. Keep it in your server's environment or secret store. |

Creating a bot establishes its identity. Your integration must still run code that receives updates and sends replies. A bot can appear in search before that code is running.

The CLI uses your signed-in account to create and manage bots. Bot API requests use the bot's token. Keep the token out of source code, browser code, and logs: anyone who has it can act as the bot.

## Inline for Mac

1. Sign in to Inline for Mac and open **Inline → Settings → Bots**.
2. Enter a name and a username ending in `bot`.
3. Select **Create Bot**.
4. Find the new bot in the bot list. Reveal its token if it is hidden, then copy it.

You can find the bot by entering its username in **⌘K** on Mac or the **Search** tab on iOS. Continue with [Verify](#verify) before connecting your integration.

## CLI

First, [install the CLI and sign in](/docs/cli#sign-in) with the account that will own the bot. Confirm the account:

```bash
inline me
```

Create the bot, replacing the name and username with your own:

```bash
inline bots create --name "My Inline Bot" --username myinlinebot
```

The command prints the bot's ID and a command for revealing its token. Normal text output does not include the token.

To find an existing bot's ID, list your bots:

```bash
inline bots list
```

Reveal the token using the ID from creation or the list. Replace `123` below with that ID. **This command prints the secret**, so run it in a private terminal without session recording or shared logs:

```bash
inline bots reveal-token --bot-user-id 123
```

## Verify

Make the token available to your shell as `INLINE_BOT_TOKEN`. The following command uses curl and a POSIX-compatible shell; it fails before sending a request if the variable is empty. It calls Bot API `0.1`:

```bash
curl -sS --max-time 15 "https://api.inline.chat/bot/getMe" \
  -H "Authorization: Bearer ${INLINE_BOT_TOKEN:?Set INLINE_BOT_TOKEN}"
```

Check the JSON response. Success has `ok: true`; `result.user.id` and `result.user.username` identify the bot. Confirm that they match the bot you created. A successful response verifies authentication; it does not mean that a reply handler is running.

If `ok` is `false`, use `error_code` and `description` to diagnose the failure. Do not treat curl's exit status alone as API success.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Bot creation fails | Use a nonempty name and an available username ending in `bot`. Usernames are case-insensitive; use letters, digits, and underscores. |
| The CLI cannot list or create bots | Run `inline me` and confirm that you are signed in with the intended owner account. |
| `getMe` rejects the token | Reveal the token again for the intended bot and update `INLINE_BOT_TOKEN`. Check for missing characters or extra whitespace. |
| The bot appears in search but does not reply | Start your integration's update consumer and reply handler. Creating the bot alone does not run either. |

## Next Steps

To receive your first message, follow [Receive Bot Updates](/docs/bot-updates). Initialize delivery **before** sending the test message; earlier messages are not backfilled. To send replies or choose a client library, continue with the [Bot API guide](/docs/bot-api).
