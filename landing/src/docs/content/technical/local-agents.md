---
title: "Local Agents"
description: "Process, workspace, ownership, and security boundaries for local coding agents."
---

[Agents](/docs/agents) covers setup and recovery. This page defines the local process boundary.

## Ownership

- Inline creates or reuses one bot identity for the selected harness.
- The local bridge owns the provider process and forwards messages between that bot and the harness.
- Existing chat bindings remain authoritative. A default workspace applies only to unbound chats.
- An explicit `--folder` selects a narrower workspace when needed.

## Security

- The bridge is local and should not expose a public listener.
- Provider credentials remain owned by the provider installation.
- Inline tokens and local control credentials must not appear in status output or logs.
- Shared and public chats do not expand local filesystem or command authority.
- A provider can request approval, but the bridge preserves the provider's exact approval or rejection scope.

## Compatibility

Codex is the primary local-bridge beta path. Claude, OpenCode, and Amp are experimental. OpenClaw and Hermes use gateway integrations.
