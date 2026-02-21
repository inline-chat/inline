# MCP

Inline MCP lets MCP-compatible clients use your Inline workspace context with explicit OAuth consent.

Use it when you want assistants to search messages and send messages in allowed spaces, DMs, and home threads.

## Status

Alpha (first-cohort release). Contracts are stable enough for early production use and may evolve.

## URL and Metadata

- MCP server URL: `https://mcp.inline.chat/mcp`
- OAuth authorization server metadata: `https://api.inline.chat/.well-known/oauth-authorization-server`
- Protected resource metadata: `https://mcp.inline.chat/.well-known/oauth-protected-resource`
- OAuth revoke endpoint: `https://api.inline.chat/oauth/revoke`

Compatibility note: `https://mcp.inline.chat/oauth/*` is proxied to the API OAuth server.

## Connect Inline MCP

### ChatGPT Apps

1. Add an MCP connector in ChatGPT Apps.
2. Set server URL to `https://mcp.inline.chat/mcp`.
3. Complete the Inline OAuth sign-in and consent flow.

### Claude

Use the same remote MCP URL:

```bash
claude mcp add --transport http inline https://mcp.inline.chat/mcp
```

Then complete the Inline OAuth sign-in flow in Claude.

### Other MCP clients

Any remote MCP client that supports OAuth 2.1 + PKCE can use:

- Server URL: `https://mcp.inline.chat/mcp`
- OAuth discovery: `https://api.inline.chat/.well-known/oauth-authorization-server`

## Authorization Flow

1. Client registers dynamically with OAuth.
2. User signs in to Inline with email code.
3. User grants scopes.
4. User selects allowed spaces and can enable `DMs` and `Home threads` (threads shared with you).
5. Client exchanges authorization code using PKCE (`S256`).
6. Refresh tokens are issued only if `offline_access` is requested.

Token lifetimes:

- Access token: 1 hour
- Refresh token: 30 days

## Scopes

- `messages:read`: required for `search` and `fetch`
- `messages:write`: required for `messages.send`
- `spaces:read`: used for space discovery and consent enforcement
- `offline_access`: enables refresh token issuance

Default scope when none is requested: `messages:read spaces:read`

## Tools

### `search`

Searches messages in approved spaces and, when enabled, approved DMs/home threads.

Input:

- `query` (string)

Returns `results[]` with:

- `id` (`inline:chat:<chatId>:msg:<messageId>`)
- `title`
- `source` (`chatId`, `title`)
- `snippet` (when available)

### `fetch`

Fetches one message by `id` from `search`.

Input:

- `id` (`inline:chat:<chatId>:msg:<messageId>`)

Returns:

- `id`, `title`, `text`
- `source` (`chatId`, `title`)
- `metadata` (`chatId`, `messageId`, `spaceId`, `fromId`, `date`)

### `messages.send`

Sends a message into an approved chat.

Input:

- `chatId` (string)
- `text` (1 to 8000 chars)
- `sendMode` (`normal` or `silent`, default `normal`)
- `parseMarkdown` (boolean, default `true`)

Returns:

- `ok`
- `chatId`
- `messageId`

## Permission Model

- Space access is limited to spaces selected during consent.
- DMs are available only when `DMs` is enabled.
- Home threads are available only when `Home threads` is enabled.
- Tool scopes are checked on every call.

## Known Limits

- Search currently returns up to 20 hits and scans up to 50 eligible chats.
- MCP sessions are in-memory; restart drops active MCP sessions.
- Each MCP session uses one Inline realtime WebSocket connection.
- Current tool surface is intentionally focused: `search`, `fetch`, `messages.send`.

## Troubleshooting

- `401 invalid_token`: reconnect and complete OAuth again.
- `403 insufficient_scope`: reconnect and grant required scopes.
- Missing expected chats: reconnect and expand consent (spaces, DMs, home threads).
- No refresh behavior: ensure client requested `offline_access`.

## MCP vs Other Inline APIs

- Use MCP for assistant workflows in MCP-native clients.
- Use [Realtime API](/docs/realtime-api) for full custom app experiences.
- Use [Bot API](/docs/bot-api) for direct HTTP bot integrations.
