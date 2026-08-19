import { describe, expect, test } from "bun:test"
import { RealtimeV3Request, RpcCall } from "@inline-chat/protocol/core"
import { InlineProtocolApplicationOutputOverloaded } from "@inline-chat/protocol/server"
import {
  InlineProtocolApplicationLanes,
  inlineProtocolRpcExecutionLane,
  makeInlineProtocolApplicationDispatcher,
} from "./application"

const deferred = () => {
  let resolve!: () => void
  const promise = new Promise<void>((done) => { resolve = done })
  return { promise, resolve }
}

describe("Inline Protocol application ordering", () => {
  test("marks execution at the application boundary and preserves output overload", async () => {
    const dispatcher = makeInlineProtocolApplicationDispatcher({
      connectionId: "test",
      operations: {
        authBegin: async () => { throw new InlineProtocolApplicationOutputOverloaded() },
        authComplete: async () => ({ state: { oneofKind: undefined } }),
      },
    })
    let executionStarted = false
    const dispatched = dispatcher.dispatch({
      payload: RealtimeV3Request.toBinary({
        body: {
          oneofKind: "authBegin",
          authBegin: { identifier: { oneofKind: undefined } },
        },
      }),
      authorization: {
        authKeyId: new Uint8Array(8),
        permanent: true,
        temporaryBound: false,
      },
      messageId: 1n,
      sessionId: 2n,
      signal: new AbortController().signal,
      markExecutionStarted: () => { executionStarted = true },
      sendUpdate: () => {},
    })

    await expect(dispatched).rejects.toBeInstanceOf(InlineProtocolApplicationOutputOverloaded)
    expect(executionStarted).toBeTrue()
  })

  test("preserves an aborted handler for secure-session outcome classification", async () => {
    const controller = new AbortController()
    const reason = new DOMException("Application deadline exceeded", "AbortError")
    const dispatcher = makeInlineProtocolApplicationDispatcher({
      connectionId: "test",
      operations: {
        authBegin: async () => {
          controller.abort(reason)
          throw reason
        },
        authComplete: async () => ({ state: { oneofKind: undefined } }),
      },
    })
    let executionStarted = false

    const dispatched = dispatcher.dispatch({
      payload: RealtimeV3Request.toBinary({
        body: {
          oneofKind: "authBegin",
          authBegin: { identifier: { oneofKind: undefined } },
        },
      }),
      authorization: {
        authKeyId: new Uint8Array(8),
        permanent: true,
        temporaryBound: false,
      },
      messageId: 1n,
      sessionId: 2n,
      signal: controller.signal,
      markExecutionStarted: () => { executionStarted = true },
      sendUpdate: () => {},
    })

    await expect(dispatched).rejects.toBe(reason)
    expect(executionStarted).toBeTrue()
  })

  test("serializes one conversation while unrelated work bypasses it", async () => {
    const lanes = new InlineProtocolApplicationLanes()
    const controller = new AbortController()
    const firstGate = deferred()
    const order: string[] = []
    const first = lanes.run("chat:1", controller.signal, async () => {
      order.push("first:start")
      await firstGate.promise
      order.push("first:end")
    })
    const second = lanes.run("chat:1", controller.signal, async () => {
      order.push("second")
    })
    const unrelated = lanes.run("chat:2", controller.signal, async () => {
      order.push("unrelated")
    })

    await unrelated
    expect(order).toEqual(["first:start", "unrelated"])
    firstGate.resolve()
    await Promise.all([first, second])
    expect(order).toEqual(["first:start", "unrelated", "first:end", "second"])
  })

  test("an aborted waiter releases its place without running", async () => {
    const lanes = new InlineProtocolApplicationLanes()
    const firstGate = deferred()
    const first = lanes.run("chat:1", new AbortController().signal, () => firstGate.promise)
    const waitingController = new AbortController()
    let ran = false
    const waiting = lanes.run("chat:1", waitingController.signal, async () => { ran = true })
    waitingController.abort()

    await expect(waiting).rejects.toBeInstanceOf(DOMException)
    expect(ran).toBe(false)
    firstGate.resolve()
    await first
    await expect(lanes.run("chat:1", new AbortController().signal, async () => 42)).resolves.toBe(42)
  })

  test("an aborted waiter cannot let later work bypass the active owner", async () => {
    const lanes = new InlineProtocolApplicationLanes()
    const firstGate = deferred()
    const order: string[] = []
    const first = lanes.run("chat:1", new AbortController().signal, async () => {
      order.push("first:start")
      await firstGate.promise
      order.push("first:end")
    })
    const waitingController = new AbortController()
    const waiting = lanes.run("chat:1", waitingController.signal, async () => {
      order.push("aborted")
    })
    waitingController.abort()
    await expect(waiting).rejects.toBeInstanceOf(DOMException)

    const later = lanes.run("chat:1", new AbortController().signal, async () => {
      order.push("later")
    })
    await Bun.sleep(5)
    expect(order).toEqual(["first:start"])

    firstGate.resolve()
    await Promise.all([first, later])
    expect(order).toEqual(["first:start", "first:end", "later"])
  })

  test("maps ordering-sensitive conversation mutations onto the same narrow lane", () => {
    const peerId = { type: { oneofKind: "chat" as const, chat: { chatId: 44n } } }
    const send = RpcCall.create({
      input: { oneofKind: "sendMessage", sendMessage: { peerId } },
    })
    const remove = RpcCall.create({
      input: { oneofKind: "deleteMessages", deleteMessages: { peerId, messageIds: [9n] } },
    })
    const unrelated = RpcCall.create({
      input: {
        oneofKind: "sendMessage",
        sendMessage: { peerId: { type: { oneofKind: "chat", chat: { chatId: 45n } } } },
      },
    })

    expect(inlineProtocolRpcExecutionLane(send)).toBe("chat:44")
    expect(inlineProtocolRpcExecutionLane(remove)).toBe("chat:44")
    expect(inlineProtocolRpcExecutionLane(unrelated)).toBe("chat:45")
  })

  test("keeps dialog, forwarding, and attachment mutations on their conversation lane", () => {
    const peerId = { type: { oneofKind: "chat" as const, chat: { chatId: 44n } } }
    const calls = [
      RpcCall.create({
        input: {
          oneofKind: "forwardMessages",
          forwardMessages: { toPeerId: peerId, messageIds: [1n] },
        },
      }),
      RpcCall.create({
        input: {
          oneofKind: "deleteMessageAttachment",
          deleteMessageAttachment: { peerId, messageId: 9n, attachmentId: 3n },
        },
      }),
      RpcCall.create({
        input: { oneofKind: "updateDialogOpen", updateDialogOpen: { peerId, open: false } },
      }),
      RpcCall.create({
        input: {
          oneofKind: "updateDialogNotificationSettings",
          updateDialogNotificationSettings: { peerId },
        },
      }),
      RpcCall.create({
        input: { oneofKind: "updateDialogArchived", updateDialogArchived: { peerId, archived: true } },
      }),
    ]

    expect(calls.map(inlineProtocolRpcExecutionLane)).toEqual(Array(5).fill("chat:44"))
  })

  test("serializes account and space mutations without blocking unrelated conversations", () => {
    const settings = RpcCall.create({
      input: { oneofKind: "updateUserSettings", updateUserSettings: {} },
    })
    const member = RpcCall.create({
      input: { oneofKind: "updateMemberAccess", updateMemberAccess: { spaceId: 8n, userId: 2n } },
    })
    const grid = RpcCall.create({
      input: { oneofKind: "toggleSpaceGrid", toggleSpaceGrid: { spaceId: 8n, enabled: true } },
    })

    expect(inlineProtocolRpcExecutionLane(settings)).toBe("account:settings")
    expect(inlineProtocolRpcExecutionLane(member)).toBe("space:8")
    expect(inlineProtocolRpcExecutionLane(grid)).toBe("space:8")
  })
})
