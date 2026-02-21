# @inline-chat/mcp

Inline MCP resource server (Bun runtime) with OAuth routed through the main API server.

## Dev

From repo root:

```sh
cd packages/mcp
bun run dev
```

Production readiness checklist: `PRODUCTION_CHECKLIST.md`.

## Endpoints (v1)

- `GET /health`
- `GET|POST|DELETE /mcp` (MCP Streamable HTTP)
- `GET /.well-known/oauth-authorization-server`
- `GET /.well-known/oauth-protected-resource`
- `POST /oauth/register` (alias: `POST /register`)
- `GET /oauth/authorize`
- `POST /oauth/authorize/send-email-code`
- `POST /oauth/authorize/verify-email-code`
- `POST /oauth/authorize/consent`
- `POST /oauth/token` (alias: `POST /token`)
- `POST /oauth/revoke` (alias: `POST /revoke`)

OAuth routes above are proxied to the API OAuth server configured by `MCP_OAUTH_PROXY_BASE_URL` (defaults to `INLINE_API_BASE_URL`).

## MCP Tools (v1)

- `search` (read-only): searches messages across approved spaces and, when enabled, DMs and home threads
- `fetch` (read-only): fetches a single message by ID returned from `search`
- `messages.send` (write): sends a message to an approved chat

ID format used by `search` results (and accepted by `fetch`):
- `inline:chat:<chatId>:msg:<messageId>`

Current payload contract:
- `search` returns JSON with `results[]` entries containing:
  - `id`
  - `title` (chat title fallback)
  - `source` (`{ chatId, title }`)
  - `snippet` (when message text exists)
- `fetch` returns JSON with:
  - `id`
  - `title` (source chat title fallback)
  - `text` (message text)
  - `source` (`{ chatId, title }`)
  - `metadata` (`chatId`, `messageId`, `spaceId`, `fromId`, `date`)
