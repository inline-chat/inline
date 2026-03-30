# OpenClaw Inline Formatting Plan

Chosen approach:

1. Follow OpenClaw's existing pattern for trusted output steering by adding config-derived `systemPrompt` support to the Inline channel config.
2. Feed group-scoped prompt text through `GroupSystemPrompt` from the inbound monitor, matching built-in OpenClaw channels.
3. Add an Inline-only outbound sanitizer via the OpenClaw `message_sending` hook so bare URLs wrapped in backticks are normalized before send.

Why this plan:

- Prompt-only guidance is not reliable enough for a user-visible formatting bug.
- Hook-only rewriting would fix the symptom but would not improve the model's behavior.
- Combining both matches upstream OpenClaw patterns and gives the smallest robust fix.

Planned files:

- `packages/openclaw-inline/src/inline/config-schema.ts`
- `packages/openclaw-inline/src/inline/monitor.ts`
- `packages/openclaw-inline/src/index.ts`
- `packages/openclaw-inline/src/index.test.ts`
- `packages/openclaw-inline/src/inline/monitor.test.ts`
- `packages/openclaw-inline/src/inline/config-schema.test.ts`
- `packages/openclaw-inline/src/inline/message-formatting.ts`
- `packages/openclaw-inline/src/inline/message-formatting.test.ts`
