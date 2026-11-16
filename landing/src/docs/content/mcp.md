---
title: "MCP"
description: "Connect an agent to Inline MCP."
---

## Connect

Codex:

```bash
codex mcp add inline --url https://mcp.inline.chat/mcp/v2
```

Claude Code:

```bash
claude mcp add --transport http inline https://mcp.inline.chat/mcp/v2
```

Amp:

```bash
amp mcp add inline https://mcp.inline.chat/mcp/v2
```

Other clients: add this as a remote Streamable HTTP server:

```text
https://mcp.inline.chat/mcp/v2
```

Complete OAuth and choose the spaces and conversation types the agent may access.

## Verify

Ask it something like:

```text
Use Inline to list my chats.
```

Messages the app sends for you show "Sent via ChatGPT" (or the app's name) under them. To let the app leave that off when you ask, check "Let it send without the Sent via label" while connecting.

---

[MCP tools](https://github.com/inline-chat/inline/tree/main/packages/mcp) · [OAuth metadata](https://api.inline.chat/.well-known/oauth-authorization-server) · [Protected resource metadata](https://mcp.inline.chat/.well-known/oauth-protected-resource)

## Source

- [MCP tools](https://github.com/inline-chat/inline/tree/main/packages/mcp)
