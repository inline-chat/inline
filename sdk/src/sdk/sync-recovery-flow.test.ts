import { it, expect, vi, afterEach } from "vitest"
import {
  Method,
  ServerProtocolMessage,
  Update,
  GetUpdatesResult_ResultType,
  SyncSkippedSequence_Reason,
  RpcError_Code,
  type RpcResult,
} from "@inline-chat/protocol/core"
import type { InlineSdkState } from "./types.js"
import { InlineSdkClient } from "./inline-sdk-client.js"
import { MockTransport } from "../realtime/mock-transport.js"

const clients: InlineSdkClient[] = []
afterEach(async () => {
  for (const c of clients.splice(0)) await c.close()
  vi.useRealTimers()
})
const flush = async () => {
  for (let i = 0; i < 80; i++) await Promise.resolve()
}
const peer = (chatId: bigint) => ({ type: { oneofKind: "chat" as const, chat: { chatId } } })
const message = (chatId: bigint, seq: number) =>
  Update.create({
    seq,
    date: 100n,
    update: {
      oneofKind: "newMessage",
      newMessage: { message: { id: BigInt(seq), chatId, fromId: 2n, peerId: peer(chatId), out: false, date: 100n } },
    },
  })
const emit = (t: MockTransport, updates: Update[]) =>
  t.emitMessage(
    ServerProtocolMessage.create({
      body: { oneofKind: "message", message: { payload: { oneofKind: "update", update: { updates } } } },
    })
  )
const result = (t: MockTransport, id: bigint, body: RpcResult["result"]) =>
  t.emitMessage(
    ServerProtocolMessage.create({ body: { oneofKind: "rpcResult", rpcResult: { reqMsgId: id, result: body } } })
  )
async function setup(
  extraState: Partial<InlineSdkState> = {},
  options: { discovery?: boolean; save?: (state: InlineSdkState) => Promise<void> } = {}
) {
  vi.useFakeTimers()
  const t = new MockTransport()
  const send = t.send.bind(t)
  t.send = async (m) => {
    await send(m)
    if (m.body.oneofKind === "ping") {
      const nonce = m.body.ping.nonce
      setTimeout(
        () => void t.emitMessage(ServerProtocolMessage.create({ body: { oneofKind: "pong", pong: { nonce } } })),
        1
      )
    }
    if (
      options.discovery !== false &&
      m.body.oneofKind === "rpcCall" &&
      m.body.rpcCall.method === Method.GET_UPDATES_STATE
    )
      await result(t, m.id, { oneofKind: "getUpdatesState", getUpdatesState: { date: 100n, updatesFound: false } })
    if (m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_ME)
      await result(t, m.id, { oneofKind: "getMe", getMe: { user: { id: 99n } } })
  }
  const c = new InlineSdkClient({
    token: "test",
    transport: t,
    state: {
      load: async () => ({
        version: 1,
        lastSeqByChatId: { "10": 1, "20": 1 },
        chatPeerByChatId: { "10": { kind: "chat", id: "10" }, "20": { kind: "chat", id: "20" } },
        ...extraState,
      }),
      save: options.save ?? (async () => {}),
    },
  })
  clients.push(c)
  const connect = c.connect()
  await flush()
  await t.connect()
  await flush()
  await t.emitMessage(ServerProtocolMessage.create({ body: { oneofKind: "connectionOpen", connectionOpen: {} } }))
  await connect
  await flush()
  return { c, t }
}
const updatesRpcs = (t: MockTransport) =>
  t.sent.filter((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES)

it.each(["timeout", "non-progress", "unaccounted-gap"])(
  "recovers a %s without another live hint or reconnect",
  async (failure) => {
    const { c, t } = await setup()
    const received: number[] = []
    const consuming = c.consumeEvents(async (e) => {
      if (e.kind === "message.new") received.push(e.seq)
    })
    await emit(t, [message(10n, 3)])
    await flush()
    const first = updatesRpcs(t)[0]!
    if (failure === "timeout") await vi.advanceTimersByTimeAsync(30_001)
    else {
      await result(t, first.id, {
        oneofKind: "getUpdates",
        getUpdates: {
          seq: failure === "non-progress" ? 1n : 3n,
          date: 100n,
          final: false,
          resultType: GetUpdatesResult_ResultType.SLICE,
          updates: failure === "non-progress" ? [] : [message(10n, 3)],
          skippedSequences: [],
        },
      })
      await flush()
    }
    expect(c.exportState().lastSeqByChatId?.["10"]).toBe(1)
    expect(received).toEqual([])
    await vi.advanceTimersByTimeAsync(1_001)
    expect(updatesRpcs(t)).toHaveLength(2)
    const retry = updatesRpcs(t)[1]!
    if (retry.body.oneofKind !== "rpcCall" || retry.body.rpcCall.input.oneofKind !== "getUpdates")
      throw Error("wrong RPC")
    expect(retry.body.rpcCall.input.getUpdates.seqEnd).toBe(3n)
    await result(t, retry.id, {
      oneofKind: "getUpdates",
      getUpdates: {
        seq: 3n,
        date: 100n,
        final: true,
        resultType: GetUpdatesResult_ResultType.SLICE,
        updates: [message(10n, 2), message(10n, 3)],
        skippedSequences: [],
      },
    })
    await flush()
    expect(received).toEqual([2, 3])
    expect(c.exportState().lastSeqByChatId?.["10"]).toBe(3)
    expect(c.getSyncStatus().state).toBe("live")
    await vi.advanceTimersByTimeAsync(120_000)
    expect(updatesRpcs(t)).toHaveLength(2)
    await c.close()
    await consuming
  }
)

it("isolates chat handlers without early cursor acknowledgement or same-chat overtaking", async () => {
  const { c, t } = await setup()
  let release!: () => void
  const held = new Promise<void>((r) => {
    release = r
  })
  const completed: string[] = []
  const consuming = c.consumeEvents(async (e) => {
    if (e.kind !== "message.new") return
    if (e.chatId === 10n && e.seq === 2) await held
    completed.push(`${e.chatId}:${e.seq}`)
  })
  await emit(t, [message(10n, 2), message(10n, 3), message(20n, 2)])
  await flush()
  expect(completed).toEqual(["20:2"])
  expect(c.exportState().lastSeqByChatId).toEqual({ "10": 1, "20": 2 })
  release()
  await flush()
  expect(completed).toEqual(["20:2", "10:2", "10:3"])
  expect(c.exportState().lastSeqByChatId).toEqual({ "10": 3, "20": 2 })
  await c.close()
  await consuming
})

it("closing during a held handler neither commits it nor revives recovery", async () => {
  const { c, t } = await setup()
  let release!: () => void
  const held = new Promise<void>((r) => {
    release = r
  })
  const consuming = c.consumeEvents(async () => held)
  await emit(t, [message(10n, 2)])
  await flush()
  await c.close()
  await consuming
  release()
  await flush()
  await vi.advanceTimersByTimeAsync(120_000)
  expect(c.exportState().lastSeqByChatId?.["10"]).toBe(1)
  expect(updatesRpcs(t)).toHaveLength(0)
})

it.each(["space", "user"])("retains autonomous %s recovery after a timeout", async (kind) => {
  const { c, t } = await setup(kind === "user" ? { lastUserSeq: 1 } : { lastSeqBySpaceId: { "30": 1 } })
  const consuming = c.consumeEvents(async () => {})
  if (kind === "space")
    await emit(t, [
      Update.create({
        update: { oneofKind: "spaceHasNewUpdates", spaceHasNewUpdates: { spaceId: 30n, updateSeq: 3 } },
      }),
    ])
  await flush()
  expect(updatesRpcs(t)).toHaveLength(1)
  await vi.advanceTimersByTimeAsync(31_001)
  expect(updatesRpcs(t)).toHaveLength(2)
  const retry = updatesRpcs(t)[1]!
  await result(t, retry.id, {
    oneofKind: "getUpdates",
    getUpdates: {
      seq: 3n,
      date: 100n,
      final: true,
      resultType: GetUpdatesResult_ResultType.SLICE,
      updates: [],
      skippedSequences: [2n, 3n].map((seq) => ({ seq, reason: SyncSkippedSequence_Reason.IRRELEVANT_TO_BUCKET })),
    },
  })
  await flush()
  expect(kind === "user" ? c.exportState().lastUserSeq : c.exportState().lastSeqBySpaceId?.["30"]).toBe(3)
  expect(c.getSyncStatus().state).toBe("live")
  await c.close()
  await consuming
})

it("coalesces new hints during backoff and cancels a pending retry on close", async () => {
  const { c, t } = await setup()
  const consuming = c.consumeEvents(async () => {})
  await emit(t, [message(10n, 3)])
  await flush()
  await vi.advanceTimersByTimeAsync(30_001)
  await emit(t, [message(10n, 4), message(10n, 5)])
  await flush()
  expect(updatesRpcs(t)).toHaveLength(1)
  await c.close()
  await consuming
  await vi.advanceTimersByTimeAsync(120_000)
  expect(updatesRpcs(t)).toHaveLength(1)
})

it.each([RpcError_Code.RATE_LIMIT, RpcError_Code.CHAT_ID_INVALID])(
  "handles authoritative RPC code %s without a retry storm",
  async (code) => {
    const { c, t } = await setup()
    const consuming = c.consumeEvents(async () => {})
    await emit(t, [message(10n, 3)])
    await flush()
    const first = updatesRpcs(t)[0]!
    await t.emitMessage(
      ServerProtocolMessage.create({
        body: { oneofKind: "rpcError", rpcError: { reqMsgId: first.id, code, message: "classified fixture" } },
      })
    )
    await flush()
    await vi.advanceTimersByTimeAsync(59_000)
    expect(updatesRpcs(t)).toHaveLength(1)
    expect(c.exportState().lastSeqByChatId?.["10"]).toBe(1)
    if (code === RpcError_Code.RATE_LIMIT) {
      await vi.advanceTimersByTimeAsync(1_001)
      expect(updatesRpcs(t)).toHaveLength(2)
    } else {
      expect(c.getSyncStatus().state).toBe("live")
      await vi.advanceTimersByTimeAsync(61_000)
      expect(updatesRpcs(t)).toHaveLength(1)
    }
    await c.close()
    await consuming
  }
)

it("repeated incomplete pages retain one bounded retry owner and the newest target", async () => {
  const { c, t } = await setup()
  const consuming = c.consumeEvents(async () => {})
  await emit(t, [message(10n, 3)])
  await flush()
  for (let index = 0; index < 3; index++) {
    const rpc = updatesRpcs(t)[index]!
    await result(t, rpc.id, {
      oneofKind: "getUpdates",
      getUpdates: {
        seq: 1n,
        date: 100n,
        final: false,
        resultType: GetUpdatesResult_ResultType.SLICE,
        updates: [],
        skippedSequences: [],
      },
    })
    await flush()
    await emit(t, [message(10n, 4), message(10n, 5)])
    await flush()
    expect(updatesRpcs(t)).toHaveLength(index + 1)
    await vi.advanceTimersByTimeAsync([1001, 2001, 4001][index]!)
    expect(updatesRpcs(t)).toHaveLength(index + 2)
  }
  const retry = updatesRpcs(t)[3]!
  if (retry.body.oneofKind !== "rpcCall" || retry.body.rpcCall.input.oneofKind !== "getUpdates")
    throw Error("wrong RPC")
  expect(retry.body.rpcCall.input.getUpdates.seqEnd).toBe(5n)
  await c.close()
  await consuming
})

it("a stale access rejection cannot discard a newer hint received during its RPC", async () => {
  const { c, t } = await setup()
  const consuming = c.consumeEvents(async () => {})
  await emit(t, [message(10n, 3)])
  await flush()
  const first = updatesRpcs(t)[0]!
  await emit(t, [message(10n, 4)])
  await flush()
  await t.emitMessage(
    ServerProtocolMessage.create({
      body: {
        oneofKind: "rpcError",
        rpcError: {
          reqMsgId: first.id,
          code: RpcError_Code.CHAT_ID_INVALID,
          message: "access changed while in flight",
        },
      },
    })
  )
  await vi.advanceTimersByTimeAsync(1_001)
  expect(updatesRpcs(t)).toHaveLength(2)
  const retry = updatesRpcs(t)[1]!
  await result(t, retry.id, {
    oneofKind: "getUpdates",
    getUpdates: {
      seq: 4n,
      date: 100n,
      final: true,
      resultType: GetUpdatesResult_ResultType.SLICE,
      updates: [message(10n, 2), message(10n, 3), message(10n, 4)],
      skippedSequences: [],
    },
  })
  await flush()
  expect(c.exportState().lastSeqByChatId?.["10"]).toBe(4)
  expect(c.getSyncStatus().state).toBe("live")
  await c.close()
  await consuming
})

it("rejecting an extra consumer does not close the healthy consumer or transport", async () => {
  const { c, t } = await setup()
  const received: number[] = []
  const consuming = c.consumeEvents(async (event) => {
    if (event.kind === "message.new") received.push(event.seq)
  })
  await expect(c.consumeEvents(async () => {})).rejects.toThrow("one consumer")
  await emit(t, [message(10n, 2)])
  await flush()
  expect(received).toEqual([2])
  expect(c.exportState().lastSeqByChatId?.["10"]).toBe(2)
  await c.close()
  await consuming
})

it("catch-up overlapping held live receipts delivers each sequence once in order", async () => {
  const { c, t } = await setup()
  let release!: () => void
  const held = new Promise<void>((resolve) => {
    release = resolve
  })
  const received: number[] = []
  const consuming = c.consumeEvents(async (event) => {
    if (event.kind !== "message.new") return
    if (event.seq === 2) await held
    received.push(event.seq)
  })
  await emit(t, [message(10n, 2), message(10n, 3), message(10n, 5)])
  await flush()
  const rpc = updatesRpcs(t)[0]!
  await result(t, rpc.id, {
    oneofKind: "getUpdates",
    getUpdates: {
      seq: 5n,
      date: 100n,
      final: true,
      resultType: GetUpdatesResult_ResultType.SLICE,
      updates: [2, 3, 4, 5].map((seq) => message(10n, seq)),
      skippedSequences: [],
    },
  })
  await flush()
  expect(received).toEqual([])
  expect(c.exportState().lastSeqByChatId?.["10"]).toBe(1)
  release()
  await flush()
  expect(received).toEqual([2, 3, 4, 5])
  expect(c.exportState().lastSeqByChatId?.["10"]).toBe(5)
  expect(c.getSyncStatus().state).toBe("live")
  await c.close()
  await consuming
})

it.each(["timeout", "checkpoint-write"])(
  "discovery recovers after %s without blocking a healthy chat",
  async (failure) => {
    let canSave = failure !== "checkpoint-write"
    const saved: InlineSdkState[] = []
    const { c, t } = await setup(
      { dateCursor: 50n },
      {
        discovery: false,
        save: async (state) => {
          if (!canSave) throw Error("state store unavailable")
          saved.push(state)
        },
      }
    )
    const received: number[] = []
    const consuming = c.consumeEvents(async (event) => {
      if (event.kind === "message.new") received.push(event.seq)
    })
    const calls = () =>
      t.sent.filter((m) => m.body.oneofKind === "rpcCall" && m.body.rpcCall.method === Method.GET_UPDATES_STATE)
    if (failure === "timeout") await vi.advanceTimersByTimeAsync(1501)
    else {
      await result(t, calls()[0]!.id, {
        oneofKind: "getUpdatesState",
        getUpdatesState: { date: 100n, updatesFound: false },
      })
      await flush()
    }
    expect(c.exportState().dateCursor).toBe(50n)
    await emit(t, [message(20n, 2)])
    await flush()
    expect(received).toEqual([2])
    canSave = true
    await vi.advanceTimersByTimeAsync(1001)
    expect(calls()).toHaveLength(2)
    const retry = calls()[1]!
    if (retry.body.oneofKind !== "rpcCall" || retry.body.rpcCall.input.oneofKind !== "getUpdatesState")
      throw Error("wrong RPC")
    expect(retry.body.rpcCall.input.getUpdatesState.date).toBe(50n)
    await result(t, retry.id, { oneofKind: "getUpdatesState", getUpdatesState: { date: 100n, updatesFound: false } })
    await flush()
    expect(saved.at(-1)?.dateCursor).toBe(100n)
    await c.close()
    await consuming
    await vi.advanceTimersByTimeAsync(120_000)
    expect(calls()).toHaveLength(2)
  }
)
