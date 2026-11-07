# OpenClaw 1.0 review

Reviewed 8 November 2026. Baseline: [PR #157](https://github.com/inline-chat/inline/pull/157), commit `3d8f57d53`. This draft is stacked on that commit; the original PR is unchanged.

## Assessment

The host migration is a useful foundation. The minimum-only host range, async API migration, SDK update, service-message filtering, and shared account client are sensible. The monitor split preserves behavior and makes the next work easier. The PR's OpenClaw source, packed consumer, and installed-host checks were green when inspected.

It is not the complete 1.0 experience. In particular, reliable inbound acceptance, Inline-owned output settings, richer progress, and grant-backed approvals remain. Treat the foundation and the full 1.0 release as separate checkpoints.

## Corrections in this draft

| Priority | Problem at the reviewed head | Correction |
| --- | --- | --- |
| P1 | Typed `command` presentation actions lose their kind and become `agent:` callbacks. Pressing `/status` can start an ordinary agent turn instead of executing a native command. | Preserve the explicit command kind through rendering and use `system:` action IDs. Opaque callback data remains agent-owned even when it looks like a command. Applies to buttons and select options. |
| P1 | The monitor renders disabled presentation buttons as live actions. | Omit their native actions; retain their labels in fallback text. |
| P2 | The monitor returns authored text before rendering presentation fallback. A URL-only control, table, or other unsupported content can disappear. | Render canonical presentation content on the direct monitor path, honor an authored `presentationTextMode: fallback`, and strip consumed presentation metadata from the outbound renderer to prevent a second flattening. |
| P2 | A cancelled caller can borrow a shared client because acquisition previously checked cancellation only through a fresh connection. | Check cancellation before borrowing, after connecting, and before invoking the leased operation. Never close the monitor's client on a cancelled lease. |
| P2 | The monitor's direct sends do not wait for explicit server flood hints. Immediate fallback sends can encounter the same rejection. | One sender owns all 15 direct monitor send sites. Retry explicit rate-limit rejections at most twice, wait the complete server hint up to 60 seconds, preserve one `randomId`, and cancel waits on monitor shutdown. Longer waits and errors without a trustworthy hint remain failures. Transport errors and unknown commit outcomes are not retried by this helper. |
| Cleanup | The plugin pins SDK 0.0.21 but still expresses Working as numeric `6`. | Use the SDK's named `WORKING` enum. |

The action parser is shared by outbound and monitor rendering; the duplicate monitor parser is removed. This remains a small mapping onto Inline's existing controls. It introduces no question framework, configuration key, protocol change, database change, or release/version bump.

The flood sender is an in-process recovery improvement. It is not a durable monitor outbox. Native outbound delivery retains the host's existing outbox and stable delivery identities. Edits, uploads, and approval-runtime sends have their existing error handling; this draft does not promise to make every RPC retryable.

## Remaining work before the full 1.0 release

### 1. Preserve inbound receipts through retry-safe acceptance — P1

`monitor.ts` calls `scheduleInboundMessage` / `scheduleImmediateInboundMessage` and returns from the SDK `consumeEvents` handler. The SDK acknowledges handler completion. These schedules live in memory; `claimInlineInboundMessageInstance` also runs before routing and dispatch. `handleInboundNow` returns after an initial metadata failure, and falls back to a stale group snapshot after some refresh failures.

Consequences: a process interruption can lose already-acknowledged scheduled work; a temporary chat/sender lookup failure can become a permanent drop; stale follow state can decide whether a bot wakes. This is existing debt carried through the PR, rather than a regression introduced by its helper extraction.

Hermes keeps the SDK receipt pending through its sidecar/adapter handoff and retries routing failures before deduplication or effects. Bridge v2 records direct input in its ledger before acknowledgement. Adopt that ownership model here while moving to the host's public inbound/turn helpers:

- Keep the receipt until the message is intentionally ignored or accepted by a durable host owner; in-memory scheduling alone is not acceptance.
- Retry unavailable metadata/provenance before marking the message handled. Preserve per-chat order while allowing other chats to proceed.
- Recheck live follow/access state before admission. Distinguish unavailable authority from a deliberate denial.
- Keep `/stop` and steering responsive. Simply awaiting an entire model turn in the SDK callback would serialize away required control behavior.
- Prove crash-before-admission replay, lookup failure then recovery, cancellation during debounce/voice wait, independent-chat progress, and acknowledgement-response loss with the real SDK event stream.

The current tests strongly exercise routing and presentation, but do not establish this end-to-end recovery property. Exactly-once model execution or external side effects should not be claimed.

### 2. Wire Inline-owned output settings and the composer — P1 for 1.0 UX

The source protocol contains `GET_AGENT_SETTINGS`, settings pushes, and `OUTPUT_MODE`, but the published SDK remains `0.0.21` with protocol `0.0.13`. The public protocol tarball inspected during this review does **not** contain `GET_AGENT_SETTINGS` or `OUTPUT_MODE`; it does contain `WORKING` and `startedAt`. Workspace source overrides can hide this distinction.

After the protocol/SDK publish:

- Declare `OUTPUT_MODE`; fetch the bot's settings and apply revisions/pushes without allowing an old fetch to overwrite a newer update.
- Resolve thread override, then bot default, then Friendly. Freeze a mode for each turn so an update cannot create half of two presentations.
- Friendly: Working and a concise final answer, with a bounded prose update only when useful. Detailed: progress and long-answer edit streaming.
- Publish `AGENT_CONFIGURATION` from the host model/reasoning catalog. The Apple composer expects item IDs `agent.model` and `agent.reasoning`; this plugin currently uses `model` and `reasoning`. Change IDs, capabilities, and mutation handling together, retaining any required compatibility for already-open settings cards.

Do not hand-code method numbers or widen SDK types to use unpublished fields. Verify a packed plugin against registry dependencies, not only the monorepo aliases.

### 3. Finish Detailed progress using Inline primitives — P1 for 1.0 UX

The richer timeline is still behind `experimentalAgentActivity`; ordinary progress is a temporary placeholder. Host events are flattened to Markdown. Port the bridge's event vocabulary and bounded document model, not its entire transport/runtime:

- One progress disclosure with a real `startedAt`, prose interleaved with tool groups, and typed statuses. Use Steps for plans, Diff for patches, Fields for approvals, and Callout for actionable failures.
- Keep the established Working header, collapsible content, and local client timer. Preserve the agreed open-state/prose behavior; a bridge implementation detail is not automatically the intended UX.
- Split at steering, questions/approvals, and size boundaries. Clear the live thought on completion. Send the final answer separately with normal notification behavior.
- Coalesce edits, bound output tails and document size, and degrade unsupported content to Markdown/plain text. Reuse the host's live-preview lifecycle where it fits instead of adding another streaming owner.
- Test recorded event sequences from more than one host runtime, including stop during tools, late terminal events, failed edits, and answers following an approval.

### 4. Make approvals genuinely grant-backed — P1 for the agreed 1.0 behavior

Approval buttons currently use the host's command authorization/config approvers and `requiredGrant = 0`. Clearing the actions leaves the original request text. That is different from Inline APPROVE grants, a visible resolved outcome, and placement in the working thread.

Implement authority and presentation together: server-enforced APPROVE requirements, current owner/delegate eligibility, the specified extra config allowance, and a resolved/expired/answered-elsewhere edit. Do not add `requiredGrant` cosmetically while leaving configured approvers unable to use the card. Keep a plain “continue” separate from approval. Continue using the host's pending approval authority rather than treating callback IDs as consent.

Typed host approval actions are still unsupported by the generic presentation mapper; the plugin's dedicated native approval runtime is the current owner. Typed questions and richer approval semantics need deliberate integration with that owner, not conversion into model callbacks.

### 5. Complete the behavior contract — P2

- **Sessions:** On-mode opener/follow-ups already share the child session. Auto-mode thread adoption still has the documented parent/child session split. Preserve privacy for guests in DM-rooted threads when addressing it.
- **Bot hand-backs:** prompt guidance and deliberate-silence handling exist, but verify the real host's no-visible-reply recovery does not force another bot response. Include a two-bot request/hand-back test and an authorized loop-cap recovery path.
- **`/new`:** a fresh host session is not automatically a fresh Inline reply thread. Implement the decided thread behavior explicitly.
- **Tool consolidation:** one `inline` tool plus `message` can reduce prompt schemas, but retain the host's read-authority fence and per-operation mutation checks. Consolidation must not create a second route around a blocked `message(read)`.
- **Status:** distinguish a successful socket/GET_ME probe from receiving, admitting, and answering messages. Report unresolved receipt/backlog and policy failures without declaring an unused chat unhealthy merely because it is quiet.
- **Setup/docs:** finish the CLI-assisted install/doctor path and migration documentation after the actual 1.0 behavior and dependency versions settle.

### 6. Keep upstream-dependent work separate

Current public SDK documentation describes more than the minimum supported release. Check both the released exports and current source before adopting question routing, fork preparation, display mentions, or child-placement bindings. Prefer public helpers and capability checks over private plugin files or version-string branches.

The official catalog/trust work remains separate. Raising the host floor or declaring `providerOwnedReadGates` does not make an external install trusted. Do not promise broad cross-chat reads until a host release includes the trusted install/catalog contract. Bot agent-session/work-bar support remains the separately planned server/protocol work.

## Validation and release qualification

Baseline: 47 files, 748 tests passed locally. Draft: `bun run check` passes type checking, lint, 48 test files / 770 tests with coverage, and the runtime/declaration build. The suite includes the packed-artifact check. PR-host CI was also green when checked.

Regressions cover rendered command dispatch through the monitor, opaque callback isolation, disabled controls, unsupported URL fallback, shared-client cancellation, bounded flood waits, stable identities, and uncertain-send suppression. The packed-artifact test checks the generated runtime bundle.

A real gateway with live bots was not used for this review. Before releasing 1.0, qualify the packed artifact on the minimum and latest host, two-bot hand-backs, group/DM Auto and On threads, a guest in a DM-rooted thread, restart/replay, approval resolution from another client, Stop/steer, and both output modes on native clients. Use the actual published protocol/SDK versions.

## Sources

- [OpenClaw 2026.11.1 release](https://github.com/openclaw/openclaw/releases/tag/v2026.11.1).
- [Native Discord presentation mapping at the minimum host](https://github.com/openclaw/openclaw/blob/v2026.11.1/extensions/discord/src/shared-interactive.ts): command/callback kind, styles, disabled state, and typed approval routing.
- [Native Slack presentation mapping](https://github.com/openclaw/openclaw/blob/23f2cd68e9d38bbffe561bada8eab5a72b9af110/extensions/slack/src/blocks-render.ts) and [Telegram approval callbacks](https://github.com/openclaw/openclaw/blob/23f2cd68e9d38bbffe561bada8eab5a72b9af110/extensions/telegram/src/approval-callback-data.ts).
- [Message presentation contract](https://docs.openclaw.ai/plugins/message-presentation) and [channel inbound API](https://docs.openclaw.ai/plugins/sdk-channel-inbound). Online documentation is current-main guidance, not proof of a minimum-host export.
- [Public inbound exports at the inspected current main](https://github.com/openclaw/openclaw/blob/23f2cd68e9d38bbffe561bada8eab5a72b9af110/src/plugin-sdk/channel-inbound.ts). Local source comparison also used `b67fef2c7`.
- Inline references: `plugins/hermes-agent/src/sidecar/inbound-delivery.ts`, `plugins/hermes-agent/src/sidecar/inbound-stream.ts`, `plugins/hermes-agent/plugin/inline/adapter.py`, `cli/src/bridge/v2/runtime.rs`, `render.rs`, `doc.rs`, `settings.rs`, `work.rs`, and `apple/InlineKit/Sources/InlineKit/Agents/ComposeAgentChainModel.swift`.
