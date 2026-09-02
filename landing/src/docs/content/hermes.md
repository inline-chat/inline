---
title: "Hermes Agent"
description: "Run Hermes Agent from Inline chats."
---

Requirements: Node.js 20+ and Hermes Agent with the external platform plugin loader (available in 0.17.x). The current adapter is validated against Hermes 0.21.0 (tag `v2026.8.31`, commit `29112bef`). Configure a model provider in Hermes before testing a conversation.

For guided setup, use `inline agents setup --target hermes`. The manual path follows.

## Install

```bash
npm install -g @inline-chat/hermes-agent-adapter
```

```bash
inline-hermes install
```

```bash
hermes plugins enable inline-platform
```

```bash
hermes gateway setup
```

Select **Inline**, then create a bot or paste an existing [bot token](/docs/creating-a-bot). Hermes stores the token with its credential helper and configures who may use the bot.

## Verify

```bash
inline-hermes doctor --json
```

```bash
hermes inline status --json --probe
```

`doctor` checks plugin files and the sidecar installation; the probe checks connectivity. Neither proves an agent turn completed. Start the gateway using your Hermes installation's normal workflow, send a small prompt to the bot in Inline, and confirm its final reply.

## Use

Message the bot in Inline, or send from Hermes. Replace `123` with the intended chat ID; this sends a real message:

```bash
hermes send --to inline:123 "Hello from Hermes"
```

To check target parsing and adapter wiring without sending:

```bash
inline-hermes test-send --dry-run --to chat:123 --text "Inline Hermes dry-run" --json
```

## Update and Troubleshoot

Update the npm package, then refresh the installed plugin bundle:

```bash
npm install -g @inline-chat/hermes-agent-adapter@latest
```

```bash
inline-hermes install --force
```

Restart the Hermes gateway after active work finishes, then rerun `doctor` and the status probe.

| Symptom | Check |
| --- | --- |
| Inline is missing from setup | Verify external plugin support and that `inline-platform` is enabled. |
| Node or sidecar check fails | Use Node 20+; if you set `INLINE_NODE_BIN`, verify it points to the intended executable. |
| Bundle hash mismatch | Refresh the plugin with `inline-hermes install --force`, then rerun `doctor`. |
| Authentication rejected | Reconfigure the bot through `hermes gateway setup`; do not paste credentials into diagnostic reports. |
| Connected but no reply | Check the allowed user policy, provider credentials, and whether the gateway is running. |

[Adapter source and reference](https://github.com/inline-chat/inline/tree/main/hermes-agent)
