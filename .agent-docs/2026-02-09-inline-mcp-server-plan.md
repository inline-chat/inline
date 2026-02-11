# Inline MCP Server (OpenAI) Plan + Spec (v1)

Date: 2026-02-09

## Goal

Create an MCP server as a new workspace package under `packages/` that can be connected from ChatGPT (OpenAI) and authenticated per Inline user, using the existing TypeScript SDK for all Inline API/RPC calls.

Constraints:
- Standalone service (separate from `server/` runtime).
- Normal user auth (no “copy token and paste into a form”).
- Explicit space selection (least privilege).
- Include write actions (at least `messages.send`) but with strong safety and scope controls.

## Non-goals (v1)

- Cross-instance persistence (Redis/KV) for OAuth transient state; v1 will use a local SQLite file (single-instance) and strict TTLs.
- Perfect relevance ranking/search indexing. v1 will use protocol `SearchMessages` and simple fallbacks.

## Architecture

- New package: `packages/mcp`
  - Runs as a Bun HTTP service (standalone), or can be mounted into the existing `server` later via a thin adapter.
  - Implements:
    - OAuth endpoints (Auth Code + PKCE + Dynamic Client Registration).
    - MCP transport endpoint (Streamable HTTP preferred; SSE fallback if needed by client compatibility).
    - Tool implementations backed by `@inline-chat/sdk`.
- Auth model (v1, normal users):
  - `GET /oauth/authorize` renders a real Inline login flow (email code) + consent screen:
    - `sendEmailCode` then `verifyEmailCode` against Inline API.
    - After verification we obtain an Inline session token and store it server-side (encrypted at rest).
  - OAuth tokens issued by the MCP server are *MCP-only* access/refresh tokens:
    - Short-lived `access_token` used by ChatGPT to call tools.
    - Rotating `refresh_token` for long-lived connectivity.
  - On each MCP tool call, the MCP server resolves the grant from the access token and uses the stored Inline token via `@inline-chat/sdk`.

## Deployment Model

- Public HTTPS endpoint (required by ChatGPT). Example:
  - Issuer: `https://mcp.inline.chat`
  - MCP endpoint: `https://mcp.inline.chat/mcp`
- Single-instance v1 backed by a local SQLite file. If/when we scale horizontally:
  - Move transient stores (auth requests, codes, refresh tokens) to a shared DB/kv.
  - Keep grant state (encrypted Inline token, scopes, space allowlist) in shared storage.

## Endpoints (Spec)

OAuth discovery:
- `GET /.well-known/oauth-authorization-server`
  - RFC 8414 document.
  - MUST point to endpoints; clients should not rely on path defaults.
- `GET /.well-known/oauth-protected-resource`
  - RFC 9728 document (recommended by MCP auth spec).

OAuth dynamic client registration (DCR):
- `POST /oauth/register` (and alias `POST /register` for fallback compatibility)
  - Accepts at minimum: `redirect_uris: string[]`, optional `client_name`.
  - Returns: `client_id`, `redirect_uris`, `token_endpoint_auth_method: "none"`, `grant_types: ["authorization_code","refresh_token"]`, `response_types: ["code"]`.
  - Stores redirect URI allowlist per client.

OAuth authorize:
- `GET /oauth/authorize` (and alias `GET /authorize`)
  - Validates: `response_type=code`, `client_id`, `redirect_uri` exact match, `state`, `code_challenge`, `code_challenge_method=S256`, `scope`.
  - Creates an `auth_request` row with TTL and sets an httpOnly cookie referencing it.
  - Renders HTML (see UI flow below).
- `POST /oauth/authorize/send-email-code`
  - Sends code via Inline API `/v1/sendEmailCode`.
- `POST /oauth/authorize/verify-email-code`
  - Verifies via Inline API `/v1/verifyEmailCode`.
  - Stores encrypted Inline token temporarily on the `auth_request`.
- `POST /oauth/authorize/consent`
  - Fetches spaces via Inline API `/v1/getSpaces` (using Inline token).
  - Requires user to pick at least 1 space (explicit allowlist).
  - Creates a `grant` row and an `auth_code` row (1-time, short TTL).
  - Redirects to `redirect_uri?code=...&state=...`.

OAuth token:
- `POST /oauth/token` (and alias `POST /token`)
  - `grant_type=authorization_code`: verify PKCE `code_verifier` (S256), code is unexpired and unused; mint access+refresh.
  - `grant_type=refresh_token`: rotate refresh token; mint new access; revoke previous refresh.
  - Response: `{ access_token, token_type: "bearer", expires_in, refresh_token? }`.

MCP:
- `GET|POST /mcp`
  - Streamable HTTP MCP endpoint.
  - Requires `Authorization: Bearer <mcp_access_token>`.
  - Validates `Origin` when present (DNS rebinding protection).

Health:
- `GET /health`

## Package Layout

- `packages/mcp/package.json`: `type: module`, scripts `dev`, `build`, `typecheck`, `test` (vitest + coverage).
- `packages/mcp/src/index.ts`: exported helpers (`createInlineMcpApp`, types).
- `packages/mcp/src/http/app.ts`: Bun `fetch()` handler and routing (or Elysia if we want).
- `packages/mcp/src/oauth/*`:
  - `register.ts`: dynamic client registration
  - `authorize.ts`: consent UI + code issuance
  - `token.ts`: code exchange + PKCE verification
  - `wellKnown.ts`: OAuth server metadata endpoint(s)
  - `store.ts`: SQLite store + TTL cleanup + strict typing
- `packages/mcp/src/mcp/*`:
  - `server.ts`: MCP server instance + tool registration
  - `transport.ts`: HTTP transport integration (streamable http; SSE if needed)
  - `tools/*`: tool implementations
- `packages/mcp/src/inline/*`:
  - `clientPool.ts`: per-access-token `InlineClient` cache (LRU + idle timeout)
  - `auth.ts`: token validation helper (calls Inline `/v1/getMe`)

## Tool Surface (v1)

Implement the minimum to work well in ChatGPT deep research and basic interactive usage.

Read-only (Deep Research compatible):
- `search(query, space_id?, chat_id?, limit?)`
  - Uses protocol `SearchMessagesInput` when a `peer_id` is available.
  - Returns result items with stable IDs + snippets + minimal metadata.
- `fetch(id)`
  - Fetches the full message (and optionally surrounding context) by ID.
  - Returns a canonical document payload.

### OpenAI Deep Research Contract Notes (2026-02-10)

For OpenAI / ChatGPT Deep Research, the MCP server should provide **two** tools named exactly:
- `search`: input should effectively be a single query string (we'll implement `{ query: string }`); output should be a JSON string with `{ results: [{ id, title, url, snippet? }] }`.
- `fetch`: input should effectively be a single ID string (we'll implement `{ id: string }`); output should be a JSON string with `{ id, title, text, url, metadata? }`.

We will implement these tools with a stable `id` scheme:
- `inline:chat:<chatId>:msg:<messageId>`

And a conservative `url` scheme:
- `inline://chat/<chatId>#message=<messageId>` (until web deep links are formalized).

Quality-of-life (Developer Mode / non-deep-research):
- `spaces.list`
- `chats.list(space_id?)`
- `messages.history(chat_id, limit, before_message_id?)`

Write actions (optional for v1, gated behind a scope):
- `messages.send(chat_id, text)`

## Tool Safety (v1)

- Scopes:
  - `spaces:read` required for `spaces.list` and `chats.list`.
  - `messages:read` required for `search`, `fetch`, `messages.history`.
  - `messages:write` required for `messages.send`.
  - `offline_access` required to issue refresh tokens.
- Space allowlist:
  - Every tool call that touches a space/chat must verify it belongs to one of the granted spaces.
  - If not, return `403` with `WWW-Authenticate: Bearer error="insufficient_scope" ...` and the resource metadata URL.
- Write confirmation:
  - `messages.send` will require explicit parameters (no hidden defaults), and will reject empty/overlong messages.
  - `messages.send` will accept `send_mode` (silent) explicitly rather than implicitly.

## UI Flow (Authorize)

Single HTML page (simple, robust, no JS required beyond optional ergonomics):
1. “Sign in to Inline” (email only)
  - Email field + “Send code”.
2. “Enter code”
  - Code field + “Verify”.
3. “Choose spaces”
  - Checkbox list of spaces (fetched after login).
  - Scope summary (read/write) and “Allow”.

Implementation details:
- CSRF: per-form CSRF token stored server-side with the `auth_request`.
- Cookies: httpOnly cookie only stores opaque `auth_request_id`; never tokens.

## Security & Abuse Controls

- Never log tokens (Inline tokens or OAuth params that contain them).
- Strict redirect URI allowlist per registered `client_id`.
- One-time auth codes; short TTL; constant-time PKCE compare.
- Rate limits (at least per-IP) on `/oauth/authorize` POST and `/oauth/token`.
- Tool-level authorization:
  - `messages.send` requires explicit `messages:write` scope.
  - Space/chat membership checked via SDK calls (or API) before returning data.
 - Store Inline session tokens encrypted at rest (AES-GCM with key from env).
 - Origin validation for MCP endpoint (if `Origin` present, must be allowlisted).
 - Host header validation (reject unexpected hosts; prevents DNS rebinding on misconfigured deployments).

## Transport & Compatibility

- Prefer MCP “streamable HTTP” transport if the SDK supports it cleanly under Bun.
- Add SSE transport if needed for compatibility with clients/inspectors.
- Provide a simple health endpoint: `GET /health`.

## Data Model (SQLite)

Tables (names indicative):
- `oauth_clients(client_id, redirect_uris_json, client_name, created_at)`
- `auth_requests(id, client_id, redirect_uri, state, scope, code_challenge, csrf_token, inline_token_enc, created_at, expires_at)`
- `grants(id, client_id, inline_user_id, scope, space_ids_json, inline_token_enc, created_at, revoked_at)`
- `auth_codes(code, grant_id, code_challenge, redirect_uri, used_at, created_at, expires_at)`
- `access_tokens(token_hash, grant_id, created_at, expires_at, revoked_at)`
- `refresh_tokens(token_hash, grant_id, created_at, expires_at, revoked_at, replaced_by_hash)`

Storage rules:
- Only store hashes for MCP access/refresh tokens.
- Only store encrypted Inline session tokens (AES-GCM).

## Testing

- Unit tests:
  - PKCE (S256) correctness
  - OAuth happy path (register -> authorize -> token)
  - Redirect URI enforcement, state passthrough, code reuse rejection
  - Tool handlers map arguments -> SDK calls -> normalized output
- Integration tests (lightweight):
  - Spin up Bun server on ephemeral port; run OAuth flow with `fetch`.
  - MCP toolcall request/response roundtrip using the chosen transport (or via library test harness).

## Milestones

1. Package skeleton + dev server + health route.
2. OAuth endpoints working end-to-end (email login + explicit space consent). (Implemented in `packages/mcp`.)
3. MCP server transport running + `search`/`fetch` + `messages.send` wired to SDK. (Next.)
4. Add `spaces.list`, `chats.list`, `messages.history`.
5. Hardening: rate limits, better errors, docs, and an OpenAI testing checklist.

## Open Questions (Need Your Call)

Resolved:
- Login method: email code only.
- Space scoping: explicit selected spaces only.

Remaining:
1. Should we allow users to re-run consent later to add more spaces/scopes (step-up), or require disconnect/reconnect in ChatGPT for v1?
2. Should the MCP issuer live on `mcp.inline.chat` or under `api.inline.chat/mcp` (still standalone, but under same domain)? Domain impacts cookie scoping and reputation.
