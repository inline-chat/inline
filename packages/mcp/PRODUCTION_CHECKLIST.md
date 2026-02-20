# Production Checklist (Inline MCP)

This package is intentionally a minimal, solid foundation. Before deploying publicly for real users, do the following.

## First-Cohort Baseline (Implemented)

### Security / Abuse
- Endpoint rate limiting is implemented for:
  - `POST /oauth/authorize/send-email-code`
  - `POST /oauth/authorize/verify-email-code`
  - `POST /oauth/token`
  - `POST /mcp` initialization requests
- Email abuse throttling is implemented for send/verify flows (per-email and per-context).
- Host/Origin allowlist checks are implemented at the app boundary.
- Grant revocation endpoint is implemented (`/oauth/revoke`, `/revoke`) and revokes grant + refresh tokens.
- Write-action audit logging for `messages.send` is implemented (no message body).

## Must-Haves (Before Broad Public Launch)

### Security / Abuse
- Add stronger anti-automation controls for email-code flow (IP reputation and/or CAPTCHA if abuse appears).
- Extend structured logging/redaction coverage beyond write audits (never log:
  - Inline session tokens
  - OAuth authorization codes
  - Refresh tokens
  - `Authorization` headers
).

### Storage / Scaling
- Decide whether v1 is single-instance only:
  - Current `/mcp` sessions are in-memory; restarts will drop sessions.
- If multi-instance or HA is needed:
  - Move OAuth transient state (`auth_requests`, `auth_codes`) + refresh tokens + grants to shared storage.
  - Move MCP session routing to either:
    - stateless transport (preferred), or
    - shared session store + sticky routing.

### Transport & Compatibility
- Verify real ChatGPT Apps connectivity against a deployed HTTPS endpoint:
  - OAuth discovery: `/.well-known/oauth-authorization-server`
  - Protected resource metadata: `/.well-known/oauth-protected-resource`
  - Dynamic client registration
  - Streamable HTTP MCP at `/mcp`
- Ensure the `search` and `fetch` tool payloads match OpenAI Deep Research expectations:
  - `search` returns JSON string: `{ results: [{ id, title, source, snippet? }] }`
  - `fetch` returns JSON string: `{ id, title, text, source, metadata? }`
- Revisit canonical link strategy later if citation-quality public links are needed.

### Privacy / Authorization
- Re-confirm the intended authorization boundaries:
  - Only explicitly selected spaces are allowed.
  - Private chats (no `spaceId`) should remain blocked unless you introduce a separate consent toggle.
- Add auditing for write actions (`messages.send`):
  - record tool name, user id, space id, chat id, timestamp, outcome (no message bodies in logs).

## Recommended (Shortly After Launch)
- Add per-grant “allowed chats” narrowing (optional) to reduce blast radius further than “space allowlist”.
- Improve search quality:
  - current v1 scans a bounded set of chats and uses `searchMessages` per chat.
  - consider adding a server-side index or a purpose-built search endpoint for cross-chat search.
- Add operational endpoints:
  - `/metrics` (if you run Prometheus), or logs-based metrics.
  - `/health` already exists.
- Add integration tests that run against a mocked Inline WS backend or a dedicated test environment.

## Current Known Tradeoffs (Intentional in Foundation)
- In-memory MCP sessions (simple, minimal; not HA).
- Inline access uses realtime WebSocket via the SDK (one WS per MCP session).
- Minimal tool surface: `search`, `fetch`, `messages.send`.
