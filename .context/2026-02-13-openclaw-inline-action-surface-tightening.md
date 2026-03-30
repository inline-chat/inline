# OpenClaw Inline Action Surface Tightening

## Goal
Tighten exposed Inline message actions to match top-level chat semantics and improve practical usability without adding a composed tool.

## Scope
- `packages/openclaw-inline/src/inline/actions.ts`
- `packages/openclaw-inline/src/inline/actions.test.ts`

## Tasks
1. Resolve `actions.ts` merge markers by selecting latest-rich baseline.
2. Tighten exposed actions:
- remove misleading `thread-reply` exposure (Inline has no subthreads)
- preserve `thread-create` / `thread-list` as aliases for top-level chat management
- add `threadName` alias support for create/edit naming
- support participant inputs beyond raw numeric IDs using Inline user resolution
3. Resolve `actions.test.ts` merge markers and cover new behavior.
4. Run focused tests for actions.

## Progress
- [x] Task 1
- [x] Task 2
- [x] Task 3
- [x] Task 4

## Notes
- Verification run:
  - `bun x vitest run packages/openclaw-inline/src/inline/actions.test.ts` (pass)
  - `cd packages/openclaw-inline && bun run typecheck` (pass)
