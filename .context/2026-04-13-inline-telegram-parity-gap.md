## Inline vs Telegram parity gap

Context:
- Fixed the Inline plugin bug where inbound text messages bypassed OpenClaw's shared inbound debouncer.
- Inline now uses `createChannelInboundDebouncer(...)` + `shouldDebounceTextInbound(...)` before `finalizeInboundContext(...)`.

Remaining gap vs Telegram native channel:
- Telegram has extra debounce behavior for forwarded burst traffic in `/Users/mo/dev/openclaw/extensions/telegram/src/bot-handlers.runtime.ts`.
- It uses a debounce lane concept (`default` vs `forward`) and allows some forward/media-only adjacent updates to coalesce into one inbound turn.
- Inline currently only debounces plain text-style inbound and explicitly keeps media/reaction/callback paths immediate.

Why this matters:
- If Inline ever emits split bursts analogous to Telegram forwards, users could still see multiple turns where Telegram would batch them.
- This is separate from the reported bug and was intentionally not folded into the current fix.

Likely follow-up:
1. Inspect whether Inline websocket updates can arrive as multi-event bursts that should be treated as one user intent.
2. If yes, add an Inline-specific debounce lane or `resolveDebounceMs(...)` strategy similar to Telegram.
3. Decide whether media-only adjacent updates should coalesce, or whether Inline semantics should stay text-only.
4. Add regression tests modeled after the Telegram debounce flush cases.

Relevant files:
- `packages/openclaw/src/inline/monitor.ts`
- `packages/openclaw/src/inline/monitor.test.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/bot-handlers.runtime.ts`
