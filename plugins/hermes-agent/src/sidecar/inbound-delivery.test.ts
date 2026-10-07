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

it.each(["message.new", "message.edit"])("typed services bypass lookup and delivery on %s", async (kind) => {
  for (const oneofKind of ["threadBacklink", "pinnedMessage"]) {
    for (const raw of [false, true]) {
      const serviceMessage = { event: { oneofKind, [oneofKind]:
        oneofKind === "threadBacklink" ? { sourceChatId: 99n } : { messageId: 3n },
      } }
      const event = message(777n)
      await deliverInboundEvent({
        ...event,
        kind,
        message: {
          ...event.message,
          message: "/threads on @bot do this now",
          ...(raw ? { raw: { serviceMessage } } : { serviceMessage }),
        },
      }, {
        meId: "777", meUsername: "bot", signal: new AbortController().signal,
        resolveSender: async () => { throw Error("service sender lookup must not run") },
        deliver: async () => { throw Error("service stream publication must not run") },
      })
    }
  }
})

it("human text matching a service fallback is still delivered", async () => {
  const event = message(777n)
  const delivered: Json[] = []
  await deliverInboundEvent({ ...event, message: { ...event.message, message: "Pinned a message · Reply in thread" } }, {
    meId: "777", meUsername: "bot", signal: new AbortController().signal,
    resolveSender: async () => ({ provenanceVerified: true, profile: { id: "42", bot: false } }),
    deliver: async (event) => { delivered.push(event) },
  })
  expect(delivered).toMatchObject([{ message: { message: "Pinned a message · Reply in thread" } }])
})

it.each([{}, { event: {} }, { futureService: { marker: true } }])("unrecognized service envelopes stay out of intake: %j", async (serviceMessage) => {
  const event = message()
  await deliverInboundEvent({ ...event, message: { ...event.message, serviceMessage } }, {
    meId: "777", meUsername: "bot", signal: new AbortController().signal,
    resolveSender: async () => { throw Error("service lookup must not run, even during outage") },
    deliver: async () => { throw Error("unknown service must not become conversation") },
  })
})

it.each([null, false, "threadBacklink", []])("nonobject service metadata preserves ordinary delivery: %j", async (serviceMessage) => {
  for (const raw of [false, true]) {
    const event = message()
    const delivered: Json[] = []
    await deliverInboundEvent({ ...event, message: { ...event.message,
      ...(raw ? { raw: { serviceMessage } } : { serviceMessage }),
    } }, {
      meId: "777", meUsername: "bot", signal: new AbortController().signal,
      resolveSender: async () => ({ provenanceVerified: true, profile: { id: "42", bot: false } }),
      deliver: async (event) => { delivered.push(event) },
    })
    expect(delivered).toHaveLength(1)
  }
})

it("service-like metadata on an action does not exclude it", async () => {
  const delivered: Json[] = []
  await deliverInboundEvent({ kind: "message.action.invoke", message: { serviceMessage: {} } }, {
    meId: "777", meUsername: "bot", signal: new AbortController().signal,
    resolveSender: async () => ({ provenanceVerified: true, profile: { id: "42", bot: false } }),
    deliver: async (event) => { delivered.push(event) },
  })
  expect(delivered).toHaveLength(1)
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
