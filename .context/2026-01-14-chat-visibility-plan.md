# Chat visibility toggle (public/private) plan

## Goals

- Add `updateChatVisibility` RPC + granular update `UpdateChatVisibility`.
- Persist visibility + participant changes to chat/user buckets and realtime.
- Add UI entry points on macOS/iOS participant management.
- Add CLI command for visibility change.

## Plan

1. Proto + server plumbing for update + server update + sync mapping. (done)
2. Server business logic: change chat visibility, manage participants/dialogs, enqueue updates, push realtime. (done)
3. Apple realtime client sync + transaction for RPC, macOS UI entry point. (done)
4. iOS participant management UI + RPC wiring. (done)
5. Web client update handler for `UpdateChatVisibility`. (done)
6. CLI command for visibility update. (done)
7. Regenerate protos + fix build errors; add/adjust tests if needed. (done; tests not run)
