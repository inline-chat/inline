# OAuth Core Migration Plan (Server + MCP)

## Goal
Move OAuth authority to the main server (Postgres/Drizzle), keep in-memory rate limits for single-instance deploy, and make MCP consume shared OAuth logic/state while preserving existing tool behavior and consent boundaries.

## Scope
- Server becomes OAuth authorization server for MCP and future third-party clients.
- OAuth entities are persisted in main DB (not MCP-local SQLite).
- Challenge-bound email OTP flow is required (`challengeToken` propagated end-to-end).
- MCP remains the resource adapter/tool runtime.

## Tasks
1. Baseline + architecture capture
- [x] Confirm current MCP/server auth flow entry points and integration boundaries.
- [x] Define server OAuth module boundaries and data contracts.

2. DB + schema
- [x] Add OAuth tables in `server/src/db/schema` and export in schema index.
- [x] Generate Drizzle migrations (no hand-written SQL).

3. Server OAuth core
- [x] Add store/repository layer (Drizzle-backed) for OAuth entities.
- [x] Implement token hashing/rotation/revocation + grant revocation semantics.
- [x] Implement in-memory per-process rate limiter module for OAuth endpoints.

4. Server HTTP endpoints
- [x] Add OAuth discovery endpoints (`/.well-known/...`).
- [x] Add register/authorize/send-email-code/verify-email-code/consent/token/revoke.
- [x] Ensure authorize flow stores and verifies `challengeToken`.

5. Shared logic extraction for MCP usage
- [x] Extract shared OAuth validation APIs usable by MCP handler.
- [x] Keep MCP-specific tool/session logic isolated in `packages/mcp`.

6. MCP integration updates
- [x] Replace MCP-local OAuth state dependency with shared server OAuth source.
- [x] Keep grant context checks (`spaces`, `allowDms`, `allowHomeThreads`).

7. Tests + validation
- [x] Add/adjust server tests for full OAuth flow and edge cases.
- [x] Add/adjust MCP tests for auth integration + grant boundaries.
- [x] Run typecheck + tests for touched packages.

## Security gates before done
- [ ] No token/code/header secret leakage in logs.
- [ ] PKCE S256 enforced for authorization code flow.
- [ ] Redirect URI strict validation.
- [ ] Hash-only storage for access/refresh tokens.
- [ ] Challenge-bound OTP verify path enforced in OAuth flow.

## Progress log
- 2026-02-20: Plan initialized.
- 2026-02-20: Added `@inline-chat/oauth-core` package with shared scope/PKCE/hash utilities and tests.
- 2026-02-20: Implemented server-authoritative OAuth (DB schema/model/controller) with in-memory rate limits and challenge-bound OTP verify.
- 2026-02-20: Switched MCP to server introspection + OAuth proxying; removed runtime SQLite dependency from MCP startup path.
- 2026-02-20: Updated MCP/server Dockerfiles to include `oauth-core` and current runtime env defaults.
- 2026-02-20: Validation completed (`oauth-core` tests/build, MCP typecheck/tests, server typecheck + OAuth/API test suites).
