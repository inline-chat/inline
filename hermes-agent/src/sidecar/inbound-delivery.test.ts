import { afterEach, expect, it, vi } from "vitest"
import { deliverInboundEvent } from "./inbound-delivery.js"
import { InlineUserDirectory } from "./user-directory.js"
import type { Json } from "./contract.js"

afterEach(() => vi.useRealTimers())
const message = (mention?: bigint) => ({
  kind: "message.new",
  chatId: 7n,
  seq: 2,
  message: {
    fromId: 42n,
    id: 2n,
    message: "hello",
    entities: { entities: mention == null ? [] : [{ entity: { oneofKind: "mention", mention: { userId: mention } } }] },
  },
})

it("a structured self mention reaches delivery while the real directory is unavailable", async () => {
  let rpcCount = 0
  const directory = new InlineUserDirectory({
    async invokeUncheckedRaw() {
      rpcCount++
      throw Error("offline")
    },
  })
  const delivered: Json[] = []
  await deliverInboundEvent(message(777n), {
    meId: "777",
    meUsername: "bot",
    signal: new AbortController().signal,
    resolveSender: () => directory.resolveWithProvenance({ userId: 42n, chatId: 7n, direct: false }),
    deliver: async (event) => {
      delivered.push(event)
    },
  })
  expect(rpcCount).toBe(0)
  expect(delivered).toMatchObject([
    {
      _inlineSenderProvenanceVerified: false,
      message: { fromId: "42", entities: { entities: [{ entity: { mention: { userId: "777" } } }] } },
    },
  ])
})

it("unverified input stays pending until real directory recovery instead of becoming a deduplicated ignore", async () => {
  vi.useFakeTimers()
  let available = false
  const directory = new InlineUserDirectory({
    async invokeUncheckedRaw() {
      if (!available) throw Error("offline")
      return { oneofKind: "getChatParticipants", getChatParticipants: { users: [{ id: 42n, bot: false }] } }
    },
  })
  const delivered: Json[] = []
  const pending = deliverInboundEvent(message(888n), {
    meId: "777",
    meUsername: "bot",
    signal: new AbortController().signal,
    resolveSender: () => directory.resolveWithProvenance({ userId: 42n, chatId: 7n, direct: false }),
    deliver: async (event) => {
      delivered.push(event)
    },
  })
  await vi.advanceTimersByTimeAsync(1)
  expect(delivered).toEqual([])
  available = true
  await vi.advanceTimersByTimeAsync(1_001)
  await pending
  expect(delivered).toMatchObject([{ sender: { id: "42", bot: false } }])
})
