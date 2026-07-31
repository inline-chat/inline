# Hermes Agent

Source: https://inline.chat/docs/hermes

Run Hermes Agent from Inline chats and reply threads. You need Node.js 20 or newer and Hermes Agent 0.17.0 or newer.

## Install

Install the adapter:

```bash
npm install -g @inline-chat/hermes-agent-adapter
```

Install and enable the Inline plugin:

```bash
inline-hermes install && hermes plugins enable inline-platform
```

Start guided setup:

```bash
hermes gateway setup
```

Select **Inline** and either create a bot with the Inline CLI or paste an existing [bot token](https://inline.chat/docs/creating-a-bot). Hermes stores the token with its credential helper and asks who may use the bot.

## Verify

```bash
inline-hermes doctor
```

## Use

Message the configured bot in Inline, or send to a chat from Hermes:

```bash
hermes send --to inline:123 "Hello from Hermes"
```

For updates, access controls, and the full feature reference, see the [Inline Hermes adapter](https://github.com/inline-chat/inline/tree/main/hermes-agent).
