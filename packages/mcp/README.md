# @inline-chat/mcp

Standalone MCP + OAuth server for Inline (Bun runtime).

## Dev

From repo root:

```sh
cd packages/mcp
bun run dev
```

## Required Env

- `MCP_ISSUER` (example: `https://mcp.inline.chat`)
- `MCP_DB_PATH` (example: `./data/inline-mcp.sqlite`)
- `MCP_TOKEN_ENCRYPTION_KEY_B64` (base64-encoded 32 bytes; used to encrypt Inline session tokens at rest)
- `INLINE_API_BASE_URL` (default: `https://api.inline.chat`)
- `MCP_COOKIE_PREFIX` (default: `inline_mcp`)

For production hardening, see `PRODUCTION_CHECKLIST.md`.

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

## MCP Tools (v1)

- `search` (read-only): searches messages across the spaces the user explicitly approved
- `fetch` (read-only): fetches a single message by ID returned from `search`
- `messages.send` (write): sends a message to a chat within an approved space

ID format used by `search` results (and accepted by `fetch`):
- `inline:chat:<chatId>:msg:<messageId>`
