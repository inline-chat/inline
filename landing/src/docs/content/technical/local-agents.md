---
title: "Local Agents"
description: "Local bridge ownership and security."
---

## Ownership

- One Inline bot identity per selected harness.
- The bridge owns the provider process.
- Existing chat bindings override the default workspace.
- `--folder` selects a narrower workspace.
- Codex is the primary local-bridge alpha path.
- Claude and OpenCode are beta; Amp is experimental.
- Hermes is beta; OpenClaw is experimental.

## Security

- Authorize senders by stable user ID.
- Owner-only routing is the default.
- Chat membership or a mention does not grant command permission.
- Do not expose the bridge as a public listener.
- Provider credentials stay with the provider.
- Tokens and local control credentials must not appear in logs.
- Shared or public chats do not expand filesystem or command authority.
- Preserve the provider's exact approval scope.

[Setup](/docs/agents) · [Bridge reference](https://github.com/inline-chat/inline/blob/main/docs/local-agent-bridge.md)
