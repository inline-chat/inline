---
title: "MCP"
description: "Connect MCP-compatible agents to Inline with OAuth consent."
---

Inline MCP gives agents scoped read and write access through OAuth consent.

## Connect an Agent

#### Codex

```bash
codex mcp add inline --url https://mcp.inline.chat/mcp/v2
```

#### Claude Code

```bash
claude mcp add --transport http inline https://mcp.inline.chat/mcp/v2
```

#### Amp

```bash
amp mcp add inline https://mcp.inline.chat/mcp/v2
```

#### Other MCP clients

```text
https://mcp.inline.chat/mcp/v2
```

Add the URL as a remote Streamable HTTP server. The client should discover OAuth automatically.

## Capabilities

- Find spaces, people, conversations, and messages.
- Read recent, unread, or surrounding message context.
- Create conversations and send text or media.
- Inspect the current account, scopes, and allowed chat context.

Agents see only the spaces selected during consent. DMs and home threads require separate grants. Every call enforces read/write scopes and allowed chat context.

## Verify Access

After signing in, ask your agent:

```text
Use Inline to list the conversations I have allowed you to access.
Do not send or change anything.
```

Then select one returned conversation and ask for a summary of its recent messages with message links. Confirm it is the intended chat before authorizing a write. Installing a skill alone does not grant access; OAuth consent still applies.

## Tool Conventions

- MCP v2 uses string IDs, including numeric-looking values. Pass the resolved `chatId` for DMs as well as threads.
- Resolve people and spaces, list conversations, and inspect the selected conversation before sending. Do not guess a destination ID from a title.
- `messages.search` searches one conversation at a time, not the whole account.
- `files.upload` accepts base64 or an HTTPS URL, with a 25 MiB limit. This is separate from native Realtime upload limits.

## Troubleshooting

- **Sign-in expired:** reconnect the server and complete OAuth again.
- **Missing conversations:** reconnect and expand the spaces or conversation types allowed during consent.
- **Write is blocked:** reconnect and grant write access.
- **Session not found:** reconnect so the client creates a new session.

Clients should honor the OAuth challenge in `_meta["mcp/www_authenticate"]` when a tool reports insufficient scope. Changing IDs or switching credentials does not resolve a missing grant.

## Reference

- [MCP source and tool reference](https://github.com/inline-chat/inline/tree/main/mcp)
- [OAuth authorization metadata](https://api.inline.chat/.well-known/oauth-authorization-server)
- [Protected resource metadata](https://mcp.inline.chat/.well-known/oauth-protected-resource)
- [Realtime API](/docs/realtime-api) for custom apps and clients
- [Bot API](/docs/bot-api) for direct HTTP bot integrations
