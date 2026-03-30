# MCP First-10 Users Production Plan (2026-02-20)

## Goal
Ship MCP in a production-ready state for an initial cohort (first ~10 users), with practical safeguards and clear docs.

## Confirmed constraints
- Persisted MCP sessions are NOT required now.
- No multi-MCP-server support required now.
- Tool outputs should not depend on links.

## Workstreams

1. Abuse protection + auth hardening
- Add endpoint rate limiting for:
  - `POST /oauth/authorize/send-email-code`
  - `POST /oauth/authorize/verify-email-code`
  - `POST /oauth/token`
  - `POST /mcp`
- Add email-based throttling for OTP send/verify attempts.
- Add Host/Origin allowlist checks (configurable).
- Add OAuth revoke endpoint and store revocation plumbing.
- Status: completed

2. MCP write-action auditing
- Add structured audit logging for `messages.send` with non-sensitive fields only.
- Include grant/user/chat/space context and success/failure outcome.
- Keep message content out of logs.
- Status: completed

3. Docs page for MCP
- Add `/docs/mcp` page with setup/auth/tools/limits for users.
- Add nav entry and route wiring.
- Keep concise docs style consistent with existing docs pages.
- Status: completed

4. Validation and readiness pass
- Extend tests for rate limits, revoke behavior, host/origin checks, and audit paths.
- Run `packages/mcp` typecheck/tests and `web` typecheck (docs route safety).
- Update production checklist + readiness note.
- Status: completed

## Exit criteria
- MCP package has practical abuse + revocation + audit safeguards for a small trusted cohort.
- Docs page exists and is discoverable in docs nav.
- Tests pass and no typecheck regressions in touched areas.
