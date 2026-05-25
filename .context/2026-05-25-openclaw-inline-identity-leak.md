## Current Finding

- The leaked `Identity / Channel: inline / User id: 1600 / AllowFrom: 1600` message is OpenClaw core's `/whoami` command reply, not model output.
- Failed speculative OpenClaw/Inline command changes were reverted before this pass.
- The concrete bug found in this pass is SDK state persistence: `InlineSdkClient` tracks `lastUserSeq` for user-bucket events, but `serializeStateV1`/`deserializeStateV1` did not store it.
- That makes native action events, including prior native command invocations, eligible to be replayed after reconnects/restarts while chat message cursors are persisted correctly.
- Chat history showed repeated plain `hi` messages followed by separate identity replies, with no visible `/whoami` user message. OpenClaw agent session logs for the matching message only saw the visible `hi`, so the identity reply is a separate command/control event.
- The remaining root cause candidate is a stale or phantom `message.action.invoke` carrying `/whoami`/`icmd:/whoami` into the callback-command path.

## Change Made

- `packages/sdk/src/state/serde.ts`
  - Persist `lastUserSeq`.
  - Restore `lastUserSeq` on deserialize.
  - Reject invalid non-number `lastUserSeq` values.
- `packages/sdk/src/state/serde.test.ts`
  - Added roundtrip coverage for `lastUserSeq`.
  - Added invalid type coverage.
- `packages/openclaw/src/inline/monitor.ts`
  - For command-like callback payloads only (`/command` and `icmd:/command`), fetch the target message and verify the callback action id and data still exist on that message before executing the command.
  - If the target action is missing, answer the callback to clear client UI state, warn, and drop it without dispatching or running `/whoami`.
  - Typed slash commands and non-command callback buttons remain on their previous paths.
- `packages/openclaw/src/inline/monitor.test.ts`
  - Added target-action fixtures for real slash/native callback command tests.
  - Added regression coverage for a stale `/whoami` callback that must be acknowledged but ignored.

## Verification

- `cd packages/sdk && ./node_modules/.bin/vitest run src/state/serde.test.ts src/sdk/inline-sdk-client.test.ts`
- `cd packages/sdk && bun run typecheck`
- `cd packages/sdk && bun run build`
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts`
- `cd packages/openclaw && bun run typecheck`
- Rebuilt OpenClaw plugin bundle manually without running the package clean script.
- Copied `packages/openclaw/dist` to local OpenClaw install.
- `openclaw gateway restart`
- `openclaw gateway health` returned OK.

## Local State

- Local installed plugin bundle contains `lastUserSeq` serializer code.
- Current state file did not contain `lastUserSeq` immediately after restart because no new user-bucket action event had been processed yet.
- Read-only live observer timed out twice without receiving a fresh Inline event from the user during the observation windows.
