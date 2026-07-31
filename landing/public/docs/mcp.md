# MCP

Source: https://inline.chat/docs/mcp

Inline MCP lets agents read and write in approved Inline spaces with OAuth consent. Use it to find context, summarize conversations, create threads, and send messages or files.

## Connect an agent

Choose your client, then complete Inline sign-in and consent in the browser.

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

In ChatGPT Apps or another MCP client, add a remote Streamable HTTP server and paste the URL above. The client should discover OAuth automatically.

## What agents can do

- Find spaces, people, conversations, and messages.
- Read recent, unread, or surrounding message context.
- Create conversations and send text or media.
- Inspect the current account, scopes, and allowed chat context.

Agents only see spaces selected during consent. Access to DMs and home threads is granted separately, and read/write scopes are enforced on every call.

## Common issues

- **Sign-in expired:** reconnect the server and complete OAuth again.
- **Missing conversations:** reconnect and expand the spaces or conversation types allowed during consent.
- **Write is blocked:** reconnect and grant write access.
- **Session not found:** reconnect so the client creates a new session.

## Reference

- [MCP source and tool reference](https://github.com/inline-chat/inline/tree/main/mcp)
- [OAuth authorization metadata](https://api.inline.chat/.well-known/oauth-authorization-server)
- [Protected resource metadata](https://mcp.inline.chat/.well-known/oauth-protected-resource)
- [Realtime API](https://inline.chat/docs/realtime-api) for custom apps and clients
- [Bot API](https://inline.chat/docs/bot-api) for direct HTTP bot integrations
