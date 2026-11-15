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
4. Choose who can message it. A new bot is private, so the app asks right away: add people or a whole space, or leave it for only you.
5. Find the new bot in the bot list. Reveal its token if it is hidden, then copy it.

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

The command prints the bot's ID, who can message it, and a command for revealing its token. Normal text output does not include the token.

A new bot is private: only you can message it. Share it in the same command:

```bash
inline bots create --name "Team Bot" --username teambot \
  --share-space 7 --share-user 456 --admin 789
```

`--share-user` and `--share-space` let a person or everyone in a space message the bot. `--admin` makes someone an admin who manages it with you. `--open` lets anyone on Inline message it. The same `--share-user`, `--share-space` and `--admin` flags work on `inline setup codex` (and the other `inline setup` commands) and on `inline agents setup`.

To find an existing bot's ID, list your bots:

```bash
inline bots list
```

Reveal the token using the ID from creation or the list. Replace `123` below with that ID. **This command prints the secret**, so run it in a private terminal without session recording or shared logs:

```bash
inline bots reveal-token --bot-user-id 123
```

## Edit a Bot

Only the bot's owner can change it.

In the apps, open the bot's chat info:

- **Mac:** **Shared With** sets who can message it. **Profile** changes the photo, name, and username. **Bot Settings** sets how it replies by default and manages its token.
- **iOS:** **Shared With** sets who can message it. **Bot Settings** has the photo, name, username, default output, and token.

Both apps also list your bots under **Settings → Bots**.

Output mode decides how an agent bot shows its work: **Detailed** posts every step, and **Friendly** posts short updates and the answer. Each bot has a default, and any thread can override it in that chat's **Agent Settings**.

From the CLI:

```bash
inline bots get --bot-user-id 123
inline bots update --bot-user-id 123 --name "Deploy Bot" --username deploy_bot
inline bots set-photo --bot-user-id 123 --file ./photo.png
inline bots remove-photo --bot-user-id 123
inline bots settings --bot-user-id 123 --output-mode friendly
inline bots settings --bot-user-id 123 --chat-id 456 --output-mode detailed
inline bots access grant --bot-user-id 123 --user-id 456
inline bots access grant --bot-user-id 123 --space-id 7
inline bots access revoke --bot-user-id 123 --user-id 456
inline bots access list --bot-user-id 123
```

Access can name one person (`--user-id`), everyone in a space you're in (`--space-id`), or everyone in a user group (`--group-id`). Bots owned by people with access can use and steer your bot too, but never approve or change its settings.

## Who Can Message a Bot

A new bot is private. Only you and the people you share it with can message it, mention it, add it to a chat or a space, or find it in search. Everyone else sees no composer in its chat and doesn't get it in the mention menu.

For a bot meant for everyone, such as a support or team bot, turn on **Anyone Can Message** under **Shared With**, or run:

```bash
inline bots access open --bot-user-id 123
inline bots access close --bot-user-id 123
```

An open bot still decides for itself who it answers. An agent set up with `inline agents` keeps answering only you and the people on its access list, so it has no **Anyone Can Message** switch.

A bot that writes to someone can be answered: for a week after a bot messages a person in their direct chat, that person can reply there even if the bot isn't shared with them. It doesn't let them start a conversation, mention the bot or add it to a chat.

Mentioning a bot follows the same rule. In a thread, a mention from someone the bot isn't shared with is sent as plain text and doesn't wake it. Add the bot to a thread and share it with the people there, and it answers them.

## Admins

A bot can have more than one person managing it, which suits a team bot. In **Shared With**, set someone's role to **Admin**, or run:

```bash
inline bots access grant --bot-user-id 123 --user-id 456 --admin
```

An admin can do what you can: choose who can message the bot, edit its name and photo, change its settings, reveal or rotate its token, and add other admins. Only the owner can delete the bot or let someone approve an agent's tool requests.

Bots created before November 2026 that don't run on an Inline agent bridge stay open to everyone until you turn that off.

`inline bots rotate-token` replaces the token and stops the old one immediately. `inline bots delete` deletes the bot and revokes its token. Both ask for confirmation.

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

## Source

- [CLI bot setup](https://github.com/inline-chat/inline/blob/main/cli/src/agents/bot.rs)
- [Server bot creation](https://github.com/inline-chat/inline/blob/main/server/src/functions/createBot.ts)
