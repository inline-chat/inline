# Hermes Agent

Use the Inline adapter to run Hermes Agent from Inline chats and reply threads.
It requires Node.js 20 or newer and Hermes Agent 0.17.0 or newer.

## Install

```bash
npm install -g @inline-chat/hermes-agent-adapter
inline-hermes install
hermes plugins enable inline-platform
hermes gateway setup
```

Select **Inline** in the messaging-platform picker. The wizard offers two setup paths:

1. Create a bot in **Inline → Settings → Bots**, then paste its token.
2. Use the Inline CLI to sign in and create the bot. The wizard can install the CLI if needed.

Hermes stores the token with its credential helper and asks which Inline users
may access the bot. See [Creating a Bot](/docs/creating-a-bot) for the manual path.

## Verify

```bash
inline-hermes doctor --json
hermes inline status
inline-hermes test-send --dry-run --to chat:123 --text "Inline Hermes dry-run" --json
```

The dry run validates the plugin without sending a message. Replace `123` with
an Inline chat ID when testing a real target.

## Use

Message the configured bot in Inline, or send to a chat from Hermes:

```bash
hermes send --to inline:123 "Hello from Hermes"
```

## Update

After upgrading the npm package, refresh the Hermes plugin copy:

```bash
npm install -g @inline-chat/hermes-agent-adapter@latest
inline-hermes install --force
inline-hermes doctor --json
```

Updating the plugin does not replace its saved token or access settings.

For environment-based setup, access controls, and the complete feature
reference, see the [Inline Hermes adapter](https://github.com/inline-chat/inline/tree/main/hermes-agent).
