# Inline OpenClaw Native Reply Threads Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add opt-in native reply-thread support to the OpenClaw Inline plugin so the bot can see, create, and reply inside real Inline reply threads while preserving today's message-reply behavior by default.

**Architecture:** Introduce a small reply-thread helper module that owns config toggle resolution and reply-thread metadata helpers, then thread that through the channel contract, outbound send path, message actions, and inbound monitor context. Keep disabled mode on the current compatibility path, and pin both enabled and disabled semantics with focused Vitest coverage before any implementation code ships.

**Tech Stack:** TypeScript, Vitest, `@inline-chat/realtime-sdk`, OpenClaw plugin SDK compatibility helpers, Bun

---

**Spec:** `docs/superpowers/specs/2026-03-29-inline-openclaw-native-reply-threads-design.md`

## File Structure

- Create: `packages/openclaw-inline/src/inline/reply-threads.ts`
  Responsibility: resolve `capabilities.replyThreads`, normalize reply-thread metadata, and provide shared helpers for channel/actions/monitor so thread logic does not sprawl across large files.
- Create: `packages/openclaw-inline/src/inline/reply-threads.test.ts`
  Responsibility: focused unit tests for toggle resolution and reply-thread helper behavior that do not need the full monitor/channel harness.
- Modify: `packages/openclaw-inline/src/inline/config-schema.ts`
  Responsibility: accept the new `capabilities.replyThreads` config shape at base and account scope.
- Modify: `packages/openclaw-inline/src/inline/config-schema.test.ts`
  Responsibility: pin schema acceptance for base/account capability toggles.
- Modify: `packages/openclaw-inline/src/inline/channel.ts`
  Responsibility: expose platform thread capability, wire the threading adapter, and route outbound sends into child reply-thread chats when enabled.
- Modify: `packages/openclaw-inline/src/inline/channel.test.ts`
  Responsibility: verify capability exposure, agent hints, and outbound thread routing in both disabled and enabled modes.
- Modify: `packages/openclaw-inline/src/inline/actions.ts`
  Responsibility: make `thread-reply` and `thread-create` use real Inline reply-thread semantics when enabled while preserving disabled-mode compatibility.
- Modify: `packages/openclaw-inline/src/inline/actions.test.ts`
  Responsibility: pin enabled/disabled action behavior, `createSubthread` usage, and clear error cases.
- Modify: `packages/openclaw-inline/src/inline/monitor.ts`
  Responsibility: detect inbound reply-thread chats, fetch parent anchor context, set `MessageThreadId`, and keep thread-scoped session/context behavior.
- Modify: `packages/openclaw-inline/src/inline/monitor.test.ts`
  Responsibility: verify inbound reply-thread context, graceful fallback when metadata is missing, and no regressions in non-threaded mention/reply flows.
- Modify: `packages/openclaw-inline/README.md`
  Responsibility: explain the new toggle and the difference between message replies and reply threads.
- Modify: `packages/openclaw-inline/docs/openclaw-setup.md`
  Responsibility: document how to enable native reply-thread support in channel config.

## Chunk 1: Config And Shared Reply-Thread Helpers

### Task 1: Add Config Acceptance And Toggle Resolution

**Files:**
- Create: `packages/openclaw-inline/src/inline/reply-threads.ts`
- Create: `packages/openclaw-inline/src/inline/reply-threads.test.ts`
- Modify: `packages/openclaw-inline/src/inline/config-schema.ts`
- Modify: `packages/openclaw-inline/src/inline/config-schema.test.ts`

- [ ] **Step 1: Write the failing schema and helper tests**

Add tests that prove all of the following:

```ts
it("accepts channels.inline.capabilities.replyThreads at the top level", () => {
  expect(
    InlineConfigSchema.safeParse({
      capabilities: { replyThreads: true },
    }).success,
  ).toBe(true)
})

it("accepts channels.inline.accounts.<account>.capabilities.replyThreads", () => {
  expect(
    InlineConfigSchema.safeParse({
      accounts: {
        work: { capabilities: { replyThreads: true } },
      },
    }).success,
  ).toBe(true)
})

it("defaults replyThreads to false when unset", () => {
  expect(isInlineReplyThreadsEnabled({ cfg: { channels: { inline: {} } } as OpenClawConfig }))
    .toBe(false)
})

it("prefers account-level replyThreads over base config", () => {
  const cfg = {
    channels: {
      inline: {
        capabilities: { replyThreads: false },
        accounts: {
          work: { token: "t", capabilities: { replyThreads: true } },
        },
      },
    },
  } satisfies OpenClawConfig

  expect(isInlineReplyThreadsEnabled({ cfg, accountId: "work" })).toBe(true)
})
```

- [ ] **Step 2: Run the focused tests to verify they fail**

Run:

```bash
bunx vitest run \
  packages/openclaw-inline/src/inline/config-schema.test.ts \
  packages/openclaw-inline/src/inline/reply-threads.test.ts
```

Expected:
- `config-schema.test.ts` fails because `capabilities` is not accepted yet.
- `reply-threads.test.ts` fails because `reply-threads.ts` does not exist yet.

- [ ] **Step 3: Implement the minimal schema and helper code**

Create `packages/openclaw-inline/src/inline/reply-threads.ts` with a focused public surface like:

```ts
export function isInlineReplyThreadsEnabled(params: {
  cfg: OpenClawConfig
  accountId?: string | null
}): boolean

export function getInlineReplyThreadsCapabilityConfig(params: {
  cfg: OpenClawConfig
  accountId?: string | null
}): { replyThreads: boolean }
```

Update `packages/openclaw-inline/src/inline/config-schema.ts` to accept:

```ts
const InlineCapabilitiesSchema = z
  .object({
    replyThreads: z.boolean().optional(),
  })
  .strict()
```

and wire it into both the base account schema and the top-level config schema.

Keep this task deliberately small:
- no channel logic yet
- no action routing yet
- just config parsing and toggle resolution

- [ ] **Step 4: Run the focused tests to verify they pass**

Run:

```bash
bunx vitest run \
  packages/openclaw-inline/src/inline/config-schema.test.ts \
  packages/openclaw-inline/src/inline/reply-threads.test.ts
```

Expected:
- PASS

- [ ] **Step 5: Commit**

```bash
git add \
  packages/openclaw-inline/src/inline/config-schema.ts \
  packages/openclaw-inline/src/inline/config-schema.test.ts \
  packages/openclaw-inline/src/inline/reply-threads.ts \
  packages/openclaw-inline/src/inline/reply-threads.test.ts
git commit -m "openclaw: add inline reply thread capability config"
```

## Chunk 2: Channel Contract And Outbound Thread Routing

### Task 2: Expose Native Thread Support In The Channel Plugin

**Files:**
- Modify: `packages/openclaw-inline/src/inline/channel.ts`
- Modify: `packages/openclaw-inline/src/inline/channel.test.ts`
- Modify: `packages/openclaw-inline/src/inline/reply-threads.ts`
- Test: `packages/openclaw-inline/src/inline/channel.test.ts`

- [ ] **Step 1: Write the failing channel tests**

Add tests that prove:

```ts
it("declares platform thread support", async () => {
  expect(inlineChannelPlugin.capabilities.threads).toBe(true)
  expect(inlineChannelPlugin.threading).toBeDefined()
})

it("keeps current outbound behavior when replyThreads is disabled", async () => {
  await inlineChannelPlugin.outbound.sendText?.({
    cfg: { channels: { inline: { token: "t", capabilities: { replyThreads: false } } } } as OpenClawConfig,
    to: "7",
    text: "hi",
    threadId: "77",
  } as any)

  expect(sendMessage).toHaveBeenCalledWith(expect.objectContaining({ chatId: 7n }))
})

it("routes outbound sendText into the child reply-thread chat when replyThreads is enabled", async () => {
  await inlineChannelPlugin.outbound.sendText?.({
    cfg: { channels: { inline: { token: "t", capabilities: { replyThreads: true } } } } as OpenClawConfig,
    to: "7",
    text: "hi",
    threadId: "77",
  } as any)

  expect(sendMessage).toHaveBeenCalledWith(expect.objectContaining({ chatId: 77n }))
})

it("routes outbound sendMedia into the child reply-thread chat when replyThreads is enabled", async () => {
  await inlineChannelPlugin.outbound.sendMedia?.({
    cfg: { channels: { inline: { token: "t", capabilities: { replyThreads: true } } } } as OpenClawConfig,
    to: "7",
    text: "hi",
    mediaUrl: "https://example.com/file.png",
    threadId: "77",
  } as any)

  expect(sendMessage).toHaveBeenCalledWith(expect.objectContaining({ chatId: 77n }))
})
```

Also add a small hint test that verifies native reply-thread guidance only appears when the toggle is on.

- [ ] **Step 2: Run the focused tests to verify they fail**

Run:

```bash
bunx vitest run packages/openclaw-inline/src/inline/channel.test.ts
```

Expected:
- FAIL because `capabilities.threads` is still `false`.
- FAIL because `threading` is currently undefined.
- FAIL because outbound send paths still ignore native `threadId`.

- [ ] **Step 3: Implement the minimal channel and outbound changes**

Update `packages/openclaw-inline/src/inline/channel.ts` so that:

```ts
capabilities: {
  chatTypes: ["direct", "group"],
  media: true,
  reactions: true,
  edit: true,
  reply: true,
  groupManagement: true,
  threads: true,
  nativeCommands: true,
  blockStreaming: true,
}
```

Add a `threading` adapter that reads the new toggle through `isInlineReplyThreadsEnabled(...)`. Keep it conservative:

```ts
threading: {
  resolveReplyToMode: () => "off",
  buildToolContext: ({ cfg, accountId, context, hasRepliedRef }) =>
    isInlineReplyThreadsEnabled({ cfg, accountId })
      ? {
          currentChannelId: context.To,
          currentThreadTs: context.MessageThreadId != null ? String(context.MessageThreadId) : undefined,
          currentMessageId: context.CurrentMessageId,
          replyToMode: "off",
          hasRepliedRef,
        }
      : undefined,
  resolveReplyTransport: ({ cfg, accountId, threadId, replyToId }) =>
    isInlineReplyThreadsEnabled({ cfg, accountId })
      ? {
          threadId: threadId != null ? String(threadId) : null,
          replyToId: replyToId ?? undefined,
        }
      : null,
}
```

For outbound `sendText` / `sendMedia`, add a shared helper in `reply-threads.ts` like:

```ts
export function resolveInlineOutboundChatId(params: {
  cfg: OpenClawConfig
  accountId?: string | null
  parentChatId: bigint
  threadId?: string | number | null
}): bigint
```

Rules:
- disabled: return `parentChatId`
- enabled + valid `threadId`: return child thread chat id
- enabled + missing `threadId`: return `parentChatId`

Do not add explicit target syntax in this task unless tests show it is required.

- [ ] **Step 4: Run the focused tests to verify they pass**

Run:

```bash
bunx vitest run packages/openclaw-inline/src/inline/channel.test.ts
```

Expected:
- PASS

- [ ] **Step 5: Commit**

```bash
git add \
  packages/openclaw-inline/src/inline/channel.ts \
  packages/openclaw-inline/src/inline/channel.test.ts \
  packages/openclaw-inline/src/inline/reply-threads.ts
git commit -m "openclaw: expose inline thread-aware channel routing"
```

## Chunk 3: Message Tool Actions For Reply Threads

### Task 3: Make `thread-reply` And `thread-create` Use Real Reply-Thread Semantics

**Files:**
- Modify: `packages/openclaw-inline/src/inline/actions.ts`
- Modify: `packages/openclaw-inline/src/inline/actions.test.ts`
- Modify: `packages/openclaw-inline/src/inline/reply-threads.ts`
- Test: `packages/openclaw-inline/src/inline/actions.test.ts`

- [ ] **Step 1: Write the failing action tests**

Add tests that prove:

```ts
it("keeps disabled-mode thread-reply compatibility behavior", async () => {
  await handleAction({
    action: "thread-reply",
    params: { threadId: "77", replyToId: "10", message: "hi" },
    cfg: { channels: { inline: { token: "t", capabilities: { replyThreads: false } } } } as OpenClawConfig,
  })

  expect(sendMessage).toHaveBeenCalledWith(
    expect.objectContaining({ chatId: 77n, replyToMsgId: 10n }),
  )
})

it("requires threadId for thread-reply when replyThreads is enabled", async () => {
  await expect(handleAction({
    action: "thread-reply",
    params: { to: "7", text: "hi" },
    cfg: enabledCfg,
  })).rejects.toThrow("inline thread-reply: threadId is required when reply threads are enabled")
})

it("sends thread-reply into the child reply-thread chat when enabled", async () => {
  await handleAction({
    action: "thread-reply",
    params: { to: "7", threadId: "77", replyToId: "10", message: "hi" },
    cfg: enabledCfg,
  })

  expect(sendMessage).toHaveBeenCalledWith(
    expect.objectContaining({ chatId: 77n, replyToMsgId: 10n }),
  )
})

it("uses createSubthread for thread-create when enabled", async () => {
  await handleAction({
    action: "thread-create",
    params: { to: "7", replyToId: "10", threadName: "Follow-up thread" },
    cfg: enabledCfg,
  })

  expect(invokeRaw).toHaveBeenCalledWith(
    expect.anything(),
    expect.objectContaining({
      oneofKind: "createSubthread",
      createSubthread: expect.objectContaining({
        parentChatId: 7n,
        parentMessageId: 10n,
        title: "Follow-up thread",
      }),
    }),
  )
})
```

Pin both anchored and unanchored `thread-create`:
- anchored: parent chat + parent message id
- unanchored: parent chat only

- [ ] **Step 2: Run the focused tests to verify they fail**

Run:

```bash
bunx vitest run packages/openclaw-inline/src/inline/actions.test.ts
```

Expected:
- FAIL because enabled-mode `thread-reply` does not require `threadId`.
- FAIL because `thread-create` still uses `createChat`.

- [ ] **Step 3: Verify available runtime method names before coding**

Check whether `@inline-chat/realtime-sdk` exposes typed `Method.CREATE_SUBTHREAD` and matching `createSubthread` oneof support. If it does not, use the plugin's forward-compatible raw escape hatch instead of widening scope to a shared SDK release in this task.

Run:

```bash
rg -n "CREATE_SUBTHREAD|createSubthread" packages/sdk src node_modules/@inline-chat/realtime-sdk
```

Expected:
- One of:
  - typed method support exists and can be used directly, or
  - no typed support exists, in which case implementation must use `invokeRaw`/`invokeUncheckedRaw` with a narrow local fallback

- [ ] **Step 4: Implement the minimal action changes**

In `packages/openclaw-inline/src/inline/actions.ts`:

- branch `thread-reply` behavior on `isInlineReplyThreadsEnabled({ cfg, accountId })`
- enabled mode:
  - require `threadId`
  - send to `chatId = BigInt(threadId)`
  - preserve optional `replyToId` as a reply inside the child thread
- disabled mode:
  - keep the current compatibility path unchanged

For `thread-create`:

- enabled mode:
  - call `createSubthread`, not `createChat`
  - derive `parentChatId` from `to` / `chatId` / `channelId`
  - map optional `replyToId` / `parentMessageId` to `parentMessageId`
  - return both `parentChatId` and the created child thread id
- disabled mode:
  - keep the current alias behavior

Use a helper shape like:

```ts
type InlineCreateSubthreadResult = {
  chatId: string
  parentChatId: string
  parentMessageId: string | null
}
```

- [ ] **Step 5: Run the focused tests to verify they pass**

Run:

```bash
bunx vitest run packages/openclaw-inline/src/inline/actions.test.ts
```

Expected:
- PASS

- [ ] **Step 6: Commit**

```bash
git add \
  packages/openclaw-inline/src/inline/actions.ts \
  packages/openclaw-inline/src/inline/actions.test.ts \
  packages/openclaw-inline/src/inline/reply-threads.ts
git commit -m "openclaw: route inline thread actions to native reply threads"
```

## Chunk 4: Inbound Monitor Context For Reply Threads

### Task 4: Detect Inbound Reply-Thread Chats And Inject Anchor Context

**Files:**
- Modify: `packages/openclaw-inline/src/inline/monitor.ts`
- Modify: `packages/openclaw-inline/src/inline/monitor.test.ts`
- Modify: `packages/openclaw-inline/src/inline/reply-threads.ts`
- Test: `packages/openclaw-inline/src/inline/monitor.test.ts`

- [ ] **Step 1: Write the failing monitor tests**

Add tests that prove:

```ts
it("sets MessageThreadId to the child thread chat id for inbound reply-thread messages", async () => {
  expect(finalizeInboundContext).toHaveBeenCalledWith(
    expect.objectContaining({
      To: "7000",
      MessageThreadId: "7100",
      ThreadLabel: "Re: deploy plan",
    }),
  )
})

it("prepends the parent anchor message into Body and InboundHistory", async () => {
  expect(finalizeInboundContext).toHaveBeenCalledWith(
    expect.objectContaining({
      Body: expect.stringContaining("Parent thread anchor"),
      InboundHistory: expect.arrayContaining([
        expect.objectContaining({ body: "Parent thread anchor" }),
      ]),
    }),
  )
})

it("falls back to current non-threaded behavior when reply-thread metadata lookup fails", async () => {
  expect(finalizeInboundContext).not.toHaveProperty("MessageThreadId")
})

it("does not merge ordinary parent-chat history into reply-thread history", async () => {
  expect(finalizeInboundContext).toHaveBeenCalledWith(
    expect.objectContaining({
      InboundHistory: expect.not.arrayContaining([
        expect.objectContaining({ body: "unrelated parent chat line" }),
      ]),
    }),
  )
})
```

- [ ] **Step 2: Run the focused tests to verify they fail**

Run:

```bash
bunx vitest run packages/openclaw-inline/src/inline/monitor.test.ts
```

Expected:
- FAIL because the monitor does not currently detect reply-thread chats or inject parent anchor context.

- [ ] **Step 3: Implement minimal reply-thread metadata loading**

Add helpers in `packages/openclaw-inline/src/inline/reply-threads.ts` that can:

```ts
export async function loadInlineReplyThreadMetadata(params: {
  client: InlineSdkClient
  chatId: bigint
}): Promise<{
  childChatId: bigint
  parentChatId: bigint
  parentMessageId: bigint | null
  title: string | null
} | null>

export async function loadInlineReplyThreadAnchorMessage(params: {
  client: InlineSdkClient
  parentChatId: bigint
  parentMessageId: bigint
}): Promise<Message | null>
```

Implementation guidance:
- `getChat(chatId)` alone is not enough because it only returns `{ chatId, peer, title }`
- use `invokeRaw(Method.GET_CHAT, ...)` when full chat fields like `parentChatId` / `parentMessageId` are required
- use `client.getMessages({ chatId: parentChatId, messageIds: [parentMessageId] })` for the anchor fetch when possible

- [ ] **Step 4: Wire monitor context through the enabled toggle**

Update `packages/openclaw-inline/src/inline/monitor.ts` so that enabled reply-thread messages:

- keep `To = parentChatId`
- set `MessageThreadId = childChatId`
- set `ThreadLabel` when the child chat title is available
- prepend the parent anchor message as the oldest synthetic history line
- keep child-thread history loading scoped to the child chat
- gracefully fall back to current behavior if metadata or anchor fetch fails

Do not disturb existing mention-gate, pending-history, or reply-to-bot behavior for normal chats.

- [ ] **Step 5: Run the focused tests to verify they pass**

Run:

```bash
bunx vitest run packages/openclaw-inline/src/inline/monitor.test.ts
```

Expected:
- PASS

- [ ] **Step 6: Commit**

```bash
git add \
  packages/openclaw-inline/src/inline/monitor.ts \
  packages/openclaw-inline/src/inline/monitor.test.ts \
  packages/openclaw-inline/src/inline/reply-threads.ts
git commit -m "openclaw: add inline inbound reply thread context"
```

## Chunk 5: Docs And Final Verification

### Task 5: Document The Toggle And Run The Full Package Checks

**Files:**
- Modify: `packages/openclaw-inline/README.md`
- Modify: `packages/openclaw-inline/docs/openclaw-setup.md`
- Verify: `packages/openclaw-inline/src/inline/reply-threads.test.ts`
- Verify: `packages/openclaw-inline/src/inline/config-schema.test.ts`
- Verify: `packages/openclaw-inline/src/inline/channel.test.ts`
- Verify: `packages/openclaw-inline/src/inline/actions.test.ts`
- Verify: `packages/openclaw-inline/src/inline/monitor.test.ts`

- [ ] **Step 1: Update the user-facing docs**

Document:
- the new `channels.inline.capabilities.replyThreads` toggle
- the per-account override path
- default-off behavior
- difference between ordinary message replies and native reply threads

- [ ] **Step 2: Run the focused reply-thread suite**

Run:

```bash
bunx vitest run \
  packages/openclaw-inline/src/inline/reply-threads.test.ts \
  packages/openclaw-inline/src/inline/config-schema.test.ts \
  packages/openclaw-inline/src/inline/channel.test.ts \
  packages/openclaw-inline/src/inline/actions.test.ts \
  packages/openclaw-inline/src/inline/monitor.test.ts
```

Expected:
- PASS

- [ ] **Step 3: Run package typecheck**

Run:

```bash
cd packages/openclaw-inline && bun run typecheck
```

Expected:
- PASS

- [ ] **Step 4: Run package build**

Run:

```bash
cd packages/openclaw-inline && bun run build
```

Expected:
- PASS

- [ ] **Step 5: Run the package test suite**

Run:

```bash
cd packages/openclaw-inline && bun run test
```

Expected:
- PASS

- [ ] **Step 6: Commit**

```bash
git add \
  packages/openclaw-inline/README.md \
  packages/openclaw-inline/docs/openclaw-setup.md \
  packages/openclaw-inline/src/inline/reply-threads.test.ts \
  packages/openclaw-inline/src/inline/config-schema.test.ts \
  packages/openclaw-inline/src/inline/channel.test.ts \
  packages/openclaw-inline/src/inline/actions.test.ts \
  packages/openclaw-inline/src/inline/monitor.test.ts
git commit -m "docs: document inline native reply thread support"
```

## Local Review Checklist

Use this checklist before executing the plan:

- disabled mode still passes the existing `thread-reply` compatibility tests
- enabled mode never silently falls back from an invalid `threadId` to the parent chat
- monitor thread history includes the parent anchor but does not accidentally include unrelated parent-chat history
- no new direct root-barrel `openclaw/plugin-sdk` runtime imports are introduced
- the helper file stays focused and does not absorb unrelated message-routing logic
