---
title: "Hermes Agent"
description: "Run Hermes Agent from Inline chats."
---

Requirements: Node.js 20+ and Hermes Agent 0.17.0+.

## Install

```bash
npm install -g @inline-chat/hermes-agent-adapter
```

```bash
inline-hermes install && hermes plugins enable inline-platform
```

```bash
hermes gateway setup
```

Select **Inline**, then create a bot or paste an existing [bot token](/docs/creating-a-bot). Hermes stores the token with its credential helper and configures who may use the bot.

## Verify

```bash
inline-hermes doctor --json
```

## Use

Message the bot in Inline, or send from Hermes:

```bash
hermes send --to inline:123 "Hello from Hermes"
```

[Adapter source and reference](https://github.com/inline-chat/inline/tree/main/hermes-agent)
