# Server Core P0 Test Implementation Plan (2026-02-14)

## Goal
Implement a deploy-safety P0 test set focused on:
- runtime crash resistance,
- key realtime/auth request paths,
- core routed endpoints that currently lack coverage,
- startup/config guardrails.

## Scope in this pass
1. Add reusable realtime test client helpers for protobuf ws messages.
2. Add test utility helper for creating valid auth sessions/tokens.
3. Add P0 realtime protocol/auth/rpc integration tests.
4. Add P0 coverage for waitlist/there/integrations callback guardrails.
5. Add P0 startup/config guard tests (`env.ts` + DB test setup guards).
6. Run focused tests and iterate until green.

## Out of scope for this pass
- Introducing a new readiness endpoint (would be product behavior change).
- Process-level crash harness with child process kill assertions.

## Progress
- [x] 1. Realtime test utilities
- [x] 2. Session helper in test utils
- [x] 3. Realtime protocol/auth/rpc tests
- [x] 4. Extra/integrations route tests
- [x] 5. Startup/config guard tests
- [x] 6. Run focused test suite and fix failures
