# Inline OpenClaw Target Semantics Fix

## Goal
Fix target ambiguity between Inline `chatId` and `userId` in the OpenClaw Inline plugin so explicit sends do not silently use wrong peer kind and surface `CHAT_INVALID`.

## Findings (cross-layer)
- Protocol/SDK supports both peer kinds (`InputPeer.chat` and `InputPeer.user`) for `SEND_MESSAGE`.
- Backend resolves peer strictly by kind; wrong kind can throw `CHAT_INVALID`.
- OpenClaw best practices for channels with ambiguous identifiers prefer explicit kind prefixes.

## Plan
1. Add durable target disambiguation in `packages/openclaw-inline/src/inline/channel.ts`.
2. Improve error messaging and target hint to clarify `chat:` vs `user:`.
3. Add focused tests in `packages/openclaw-inline/src/inline/channel.test.ts`.
4. Run package tests and summarize production readiness.
5. Polish resolver ergonomics for explicit `user:` targets and `inline:user:`/`inline:chat:` normalization.

## Progress
- [x] Analyze protocol + SDK + backend + OpenClaw target resolution behavior.
- [x] Implement disambiguation + error improvements.
- [x] Add/adjust tests.
- [x] Run tests and finalize report.
- [x] Polish ergonomics so user targets stay explicit in directory/resolver outputs.

## Validation
- `cd packages/openclaw-inline && bun x vitest run src/inline/channel.test.ts`
- `cd packages/openclaw-inline && bun x vitest run`
- `cd packages/openclaw-inline && bun run typecheck`
- `cd packages/openclaw-inline && bun run build`

## Follow-up Polish
- `looksLikeInlineTargetId` now recognizes explicit `user:<id>` and `inline:user:<id>` as ID-like to avoid unnecessary directory lookups.
- `normalizeInlineTarget` now canonicalizes explicit user targets and accepts `inline:user:<id>` / `inline:chat:<id>`.
- Added normalization tests in `src/inline/normalize.test.ts` and docs note in README.
- Directory user IDs now return as `user:<id>` (including group members) and `resolver.resolveTargets(kind=user)` now returns `user:<id>`, reducing accidental chat/user id mixups.
- Outbound delivery results now report user-target sends as `chatId: "user:<id>"` so operator output is explicit.
- Added `agentPrompt.messageToolHints` guidance for Inline target semantics in OpenClaw agents.
