# MCP

Inline MCP exposes a focused tool surface for MCP-compatible clients (for example ChatGPT) to search and send messages in Inline.

Use it when you want an assistant to work with real team context, with explicit per-space consent.

## Status

Alpha. Tool contract and consent UX may evolve.

## Endpoint

- MCP server: `https://mcp.inline.chat/mcp`
- OAuth metadata: `https://mcp.inline.chat/.well-known/oauth-authorization-server`
- Protected resource metadata: `https://mcp.inline.chat/.well-known/oauth-protected-resource`
- OAuth revoke: `https://mcp.inline.chat/oauth/revoke`

## Quick Start (First Use)

1. Add the MCP server URL: `https://mcp.inline.chat/mcp`.
2. Sign in with your Inline email code.
3. Select scopes and choose the spaces to allow.
4. Start with `search`, then `fetch`, then `messages.send`.

### Client Notes

- ChatGPT Apps: use the MCP server URL above and complete the OAuth sign-in flow.
- Claude: add the same remote MCP URL and complete OAuth in Claude's connector flow.

## Auth Flow

1. MCP client registers via OAuth dynamic client registration.
2. User signs in with Inline email code.
3. User approves scopes.
4. User selects one or more spaces to allow.
5. Client exchanges authorization code with PKCE (`S256`) and receives an access token.
6. Refresh token is issued only when `offline_access` is requested.

Current token lifetimes:

- Access token: 1 hour
- Refresh token: 30 days

## Scopes

- `messages:read`: required for `search` and `fetch`.
- `messages:write`: required for `messages.send`.
- `spaces:read`: used for space discovery and consent checks.
- `offline_access`: enables refresh token issuance.

If no scope is requested, the default is `messages:read spaces:read`.

## Tools

### `search`

Searches messages in approved spaces.

Input:

- `query` (string)

Output includes `results[]` entries with:

- `id` (`inline:chat:<chatId>:msg:<messageId>`)
- `title`
- `source` (`chatId`, `title`)
- `snippet` (if text exists)

### `fetch`

Fetches one message by ID from `search`.

Input:

- `id` (`inline:chat:<chatId>:msg:<messageId>`)

Output includes:

- `id`, `title`, `text`
- `source` (`chatId`, `title`)
- `metadata` (`chatId`, `messageId`, `spaceId`, `fromId`, `date`)

### `messages.send`

Sends a text message into an approved chat.

Input:

- `chatId` (string)
- `text` (1 to 8000 chars)
- `sendMode` (`normal` or `silent`, default `normal`)
- `parseMarkdown` (boolean, default `true`)

Output includes:

- `ok`
- `chatId`
- `messageId`

## Safety Boundaries

- Access is limited to spaces explicitly selected during consent.
- Chats without a space (for example DMs) are blocked in v1.
- Scope checks are enforced per tool call.
- `fetch` validates message ID format and still enforces space boundaries.
- `messages.send` can only target chats in approved spaces.

## Known Limits

- Search is bounded to 20 total hits and scans up to 50 eligible chats.
- MCP sessions are in-memory; restarts drop active sessions.
- Each MCP session uses one Inline realtime WebSocket connection.
- Tool surface is intentionally minimal: `search`, `fetch`, `messages.send`.

## When To Use MCP vs Other APIs

- Use MCP for assistant-driven workflows in MCP clients.
- Use [Realtime API](/docs/realtime-api) for full custom apps.
- Use [Bot API](/docs/bot-api) for simple HTTP bot flows.
