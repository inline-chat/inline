# OpenClaw Inline Plugin Alpha Polish Plan (2026-02-12)

## Scope

Align `packages/openclaw-inline` with latest OpenClaw plugin/channel contracts, remove legacy duplicate implementation, strengthen monitor test coverage, and prepare package metadata/docs for imminent public publish.

## Plan

1. Validate latest OpenClaw remote specs and contract deltas
   - Status: completed
2. Apply contract alignment in plugin code (routing/chat kind/thread semantics if needed)
   - Status: completed
3. Remove legacy implementation files/tests not used by build/runtime
   - Status: completed
4. Add focused monitor tests for minimal DM/group + reply mapping behavior
   - Status: completed
5. Publish readiness polish
   - Status: completed
   - Set package public metadata, tighten README language, ensure manifest/install guidance consistent
6. Final verification
   - Status: completed
   - Run package tests + build, then summarize remaining alpha risks (if any)

## Second Pass (Release Readiness)

1. Re-verify latest OpenClaw remote route/chat-type contracts
   - Status: completed
2. Tighten user id normalization (`inline:` + `user:` prefixes)
   - Status: completed
3. Add additional contract tests (minimal capabilities + prefix behavior)
   - Status: completed
4. Run full package validation + publish dry-run
   - Status: completed
