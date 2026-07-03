# MCP

Inline MCP lets MCP-compatible clients use your Inline workspace with explicit OAuth consent.

Use it when you want assistants to read conversations, search/list messages, create conversations, and send text/media in approved contexts.

## Status

Alpha (first-cohort release). Stable enough for early production usage; surface may evolve.

## Quick Setup

### ChatGPT Apps

1. Add an MCP connector in ChatGPT Apps.
2. Set server URL to `https://mcp.inline.chat/mcp`.
3. Complete Inline OAuth sign-in and consent.

### Claude

```bash
claude mcp add --transport http inline https://mcp.inline.chat/mcp
```

Then complete Inline OAuth sign-in in Claude.

### Other MCP clients

Any remote MCP client with OAuth 2.1 + PKCE (`S256`) can connect using:

- Server URL: `https://mcp.inline.chat/mcp`
- OAuth metadata: `https://api.inline.chat/.well-known/oauth-authorization-server`
- Protected resource metadata: `https://mcp.inline.chat/.well-known/oauth-protected-resource`

Compatibility: `https://mcp.inline.chat/oauth/*` is proxied to the Inline OAuth server.

## OAuth and Scopes

Authorization flow:

1. Client performs dynamic OAuth registration.
2. User signs in to Inline.
3. User grants scopes.
4. User chooses allowed spaces and can enable `DMs` and `Home threads`.
5. Client exchanges authorization code with PKCE (`S256`).
6. Refresh token is issued only when `offline_access` is requested.

Default token lifetimes:

- Access token: 1 hour
- Refresh token: 30 days

Scopes:

- `messages:read`
- `messages:write`
- `spaces:read`
- `offline_access`

Default scope when none is requested: `messages:read spaces:read`

## Permission Model

- Space access is limited to spaces selected during consent.
- DM access is available only if `DMs` is enabled.
- Home-thread access is available only if `Home threads` is enabled.
- Tool scopes are enforced on every call.

## Tools

Current MCP tools are grouped around agent workflows instead of raw API endpoints:

- `account.me`: inspect the current authorization, granted scopes, and allowed chat context.
- `spaces.list`: list spaces visible to the current grant.
- `people.search`: resolve people by name, username, or user ID in allowed contexts.
- `conversations.list`: list recent conversations or resolve a conversation by name/title/ID.
- `conversations.get`: inspect one resolved chat or DM, including participants and pinned message IDs.
- `conversations.create`: create a new conversation in an allowed space or home threads.
- `messages.list`: list recent messages in one chat or DM with filters (`since`, `until`, `content`, etc).
- `messages.context`: fetch a before/after window around a message ID, or latest compact context.
- `messages.search`: search messages in one chat or DM (not global search).
- `messages.unread`: list unread messages across approved conversations.
- `messages.send`: send a text message to a chat or DM.
- `files.upload`: upload media from `base64` or an HTTPS URL and get Inline media IDs.
- `files.get`: extract file/media metadata from specific message IDs or recent messages.
- `messages.send_media`: send uploaded photo/video/document with optional caption.
- `messages.send_batch`: send ordered text/media items in one call.

Legacy tools `search` and `fetch` are removed.

## Entity URIs

Chat, message, and person entities include a canonical `uri` field using Inline deep links:

```text
inline://chat/{chatId}
inline://chat/{chatId}/message/{messageId}
inline://user/{userId}
```

Use IDs for tool calls. Use `uri` when showing, storing, or handing links back to a user.

## Common Workflows

- Inspect the current grant: `account.me`.
- Resolve a target: `spaces.list` or `people.search`, then `conversations.list`, then `conversations.get`.
- Summarize a thread: `messages.list` with `since`/`until`, then summarize in the model.
- Read around a found message: `messages.search` or `messages.unread`, then `messages.context`.
- Find links/media/files: `messages.search` with `content: "links" | "media" | "files"`, or `files.get` for concrete file metadata.
- Create a thread then post: `conversations.create`, then `messages.send`.
- Send media: `files.upload`, then `messages.send_media`.
- Import a compact batch: `conversations.create`, then `messages.send_batch`.

## Limits

- `messages.list` and `messages.search`: up to 50 messages per call.
- `messages.unread`: up to 200 messages per call.
- `messages.send_batch`: up to 100 items per call.
- `files.upload`: max file size 25 MB.
- `files.upload` URL source: HTTPS only, private/local network targets are blocked, up to 3 redirects.
- New MCP session initialization (`POST /mcp` without `mcp-session-id`) is rate-limited per IP.
- MCP sessions are in-memory and have idle expiry; server restart drops active sessions.
- Each active MCP session uses one Inline realtime WebSocket connection.

## Agent Compatibility

- Tools advertise output schemas, annotations, and `_meta.securitySchemes` through `tools/list`.
- Tool responses include structured content plus a JSON text fallback for clients that need text content.
- Missing read/write scopes return normal MCP tool errors with `_meta["mcp/www_authenticate"]` so compatible clients can reauthorize without treating the request as a server failure.
- Time filters accept natural values such as `today`, `yesterday`, `2d ago`, `YYYY-MM-DD`, or epoch seconds.

## Troubleshooting

- `401 invalid_token`: reconnect and complete OAuth again.
- `403 insufficient_scope`: reconnect and grant needed scopes.
- `429 rate_limited`: wait and retry initialization.
- `404 unknown_session`: session expired/restarted; reconnect to create a new session.
- Missing expected chats: reconnect and expand consent (spaces, DMs, home threads).
- No refresh behavior: ensure client requested `offline_access`.

## MCP vs Other Inline APIs

- Use MCP for assistant workflows in MCP-native clients.
- Use [Realtime API](/docs/realtime-api) for fully custom client/app integrations.
- Use [Bot API](/docs/bot-api) for direct HTTP bot integrations.
