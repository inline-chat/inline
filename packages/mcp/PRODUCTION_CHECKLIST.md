# Production Checklist (Inline MCP)

This package is intentionally a minimal, solid foundation. Before deploying publicly for real users, do the following.

## Must-Haves (Before Public Launch)

### Security / Abuse
- Add rate limiting for:
  - `POST /oauth/authorize/send-email-code`
  - `POST /oauth/authorize/verify-email-code`
  - `POST /oauth/token`
  - `POST /mcp` (tool calls)
- Add bot/abuse protection for email-code flow (IP reputation, per-email throttles, possibly CAPTCHA if needed).
- Add structured logs with strict redaction (never log:
  - Inline session tokens
  - OAuth authorization codes
  - Refresh tokens
  - `Authorization` headers
).
- Validate/lock down allowed `Host` and (when present) `Origin` headers at the edge (DNS rebinding protection).
- Add a grant revocation endpoint and persistence path:
  - At minimum: mark `grants.revoked_at` and revoke refresh tokens.

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
  - `search` returns JSON string: `{ results: [{ id, title, url, snippet? }] }`
  - `fetch` returns JSON string: `{ id, title, text, url, metadata? }`
- Replace placeholder `inline://...` URLs with real web deep links once available (or define a stable public URL scheme).

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

