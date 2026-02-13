# Realtime SDK RPC Retry Plan (2026-02-13)

## Goal
Add robust in-memory pending RPC retry for response-waiting calls (`callRpc` path), retrying after reconnect/auth-open, with configurable default timeout (30s default) and optional infinite timeout.

## Tasks
- [x] 1) Implement pending RPC request map and resend-on-open flow in `ProtocolClient`.
- [x] 2) Add configurable default RPC timeout (30s default, infinite supported) and wire from SDK options.
- [x] 3) Update/expand tests for queue-before-open, retry-after-reconnect, timeout behavior, and non-retry raw path.
- [x] 4) Run `packages/sdk` tests and typecheck.

## Notes
- Retry behavior applies only to response-waiting RPCs (`callRpc`) and not fire-and-forget/raw send path (`sendRpc`).
- Pending calls are retried only after auth completion (`connectionOpen`).
- Explicit shutdown still rejects pending calls with `stopped`.
