import { PassThrough, Readable } from "node:stream"
import { expect, it, vi } from "vitest"
import {
  Method,
  ServerProtocolMessage,
  Update,
  type RpcResult,
  type ClientMessage,
  InlineSdkClient,
} from "@inline-chat/realtime-sdk"
import { deliverInboundEvent } from "../src/sidecar/inbound-delivery.js"
import { InboundStream } from "../src/sidecar/inbound-stream.js"
import { InlineUserDirectory } from "../src/sidecar/user-directory.js"

const flush = async () => {
  for (let i = 0; i < 10; i++) await new Promise<void>(resolve => setImmediate(resolve))
}

it.each(["recover", "abort", "missing-direct", "missing-group"])("real SDK, directory and stream isolate held sender lookup across %s", async action => {
  // Script only the remote wire; all SDK, directory and delivery objects are real.
  const successfulMiss = action.startsWith("missing-")
  const direct = action === "missing-direct"
  let now = 0
  let actorPresent = false
  const wire = new Readable({ objectMode: true, read() {} })
  const transport = {
    events: wire,
    sent: [] as ClientMessage[],
    async start() {
      wire.push({ type: "connecting" })
    },
    async stop() {
      wire.push({ type: "stopping" })
      wire.push(null)
    },
    async stopConnection() {},
    async reconnect() {
      wire.push({ type: "connecting" })
    },
    async connect() {
      wire.push({ type: "connected" })
    },
    async emitMessage(message: ServerProtocolMessage) {
      wire.push({ type: "message", message })
    },
    async send(message: ClientMessage) {
      this.sent.push(message)
    },
  }
  const reply = (id: bigint, result: RpcResult["result"]) =>
    transport.emitMessage(
      ServerProtocolMessage.create({
        body: { oneofKind: "rpcResult", rpcResult: { reqMsgId: id, result } },
      })
    )
  const send = transport.send.bind(transport)
  transport.send = async (message) => {
    await send(message)
    if (message.body.oneofKind !== "rpcCall") return
    if (message.body.rpcCall.method === Method.GET_ME)
      await reply(message.id, { oneofKind: "getMe", getMe: { user: { id: 777n } } })
    if (message.body.rpcCall.method === Method.GET_UPDATES_STATE)
      await reply(message.id, { oneofKind: "getUpdatesState", getUpdatesState: { date: 100n, updatesFound: false } })
    const users = successfulMiss
      ? [{ id: 41n, firstName: "Known sender" }, ...(actorPresent ? [{ id: 42n, firstName: "Jack" }] : [])]
      : [{ id: 42n, firstName: "Jack" }]
    if (message.body.rpcCall.method === Method.GET_CHATS)
      await reply(message.id, { oneofKind: "getChats", getChats: { users } })
    if (successfulMiss && message.body.rpcCall.method === Method.GET_CHAT_PARTICIPANTS)
      await reply(message.id, { oneofKind: "getChatParticipants", getChatParticipants: { users } })
  }
  const client = new InlineSdkClient({
    token: "test",
    transport,
    state: {
      load: async () => ({ version: 1, lastSeqByChatId: { "10": 1, "20": 1 } }),
      save: async () => {},
    },
  })
  const directory = new InlineUserDirectory(client, { now: () => now })
  const stream = new InboundStream()
  const consumer = new PassThrough()
  const lines: string[] = []
  consumer.on("data", (chunk) => lines.push(chunk.toString()))
  stream.attach(consumer)
  const abort = new AbortController()
  let consuming: Promise<void> | undefined
  try {
    const connecting = client.connect()
    await flush()
    await transport.connect()
    await flush()
    await transport.emitMessage(
      ServerProtocolMessage.create({ body: { oneofKind: "connectionOpen", connectionOpen: {} } })
    )
    await connecting
    if (successfulMiss) {
      // Warm a successful collection which contains a different actor. Its
      // positive TTL must not strand a new sender missing from that response.
      expect(await directory.resolveWithProvenance({ userId: 41n, chatId: 10n, direct }))
        .toMatchObject({ provenanceVerified: true, profile: { id: "41", bot: false } })
    }
    consuming = client.consumeEvents(async (event) =>
      deliverInboundEvent(event, {
        meId: "777",
        meUsername: "bot",
        signal: abort.signal,
        resolveSender: (event) =>
          directory.resolveWithProvenance({ userId: 42n, chatId: BigInt(event.chatId as bigint), direct }),
        deliver: (event) => stream.deliver(event),
      })
    )
    const message = (chatId: bigint, mention: boolean, seq = 2) =>
      Update.create({
        seq,
        date: 100n,
        update: {
          oneofKind: "newMessage",
          newMessage: {
            message: {
              id: BigInt(seq),
              chatId,
              fromId: 42n,
              peerId: direct && chatId === 10n
                ? { type: { oneofKind: "user", user: { userId: 42n } } }
                : { type: { oneofKind: "chat", chat: { chatId } } },
              entities: {
                entities: mention
                  ? [{ offset: 0, length: 4, entity: { oneofKind: "mention", mention: { userId: 777n } } }]
                  : [],
              },
            },
          },
        },
      })
    await transport.emitMessage(
      ServerProtocolMessage.create({
        body: {
          oneofKind: "message",
          message: {
            payload: { oneofKind: "update", update: { updates: [message(10n, false), message(20n, true), message(10n, false, 3)] } },
          },
        },
      })
    )
    await flush()
    expect(lines.map((line) => JSON.parse(line).chatId)).toEqual(["20"])
    expect(JSON.parse(lines[0]!)._inlineSenderProvenanceVerified).toBe(false)
    // Bytes reaching Python are not application completion. A healthy chat can
    // acknowledge while the other chat's sender/preflight is still pending.
    expect(client.exportState().lastSeqByChatId).toEqual({ "10": 1, "20": 1 })
    stream.acknowledge(JSON.parse(lines[0]!)._inlineDeliveryId)
    await flush()
    expect(client.exportState().lastSeqByChatId).toEqual({ "10": 1, "20": 2 })
    if (action === "abort") {
      abort.abort()
      await client.close()
      await consuming
      expect(lines.map(line => JSON.parse(line).chatId)).toEqual(["20"])
      expect(client.exportState().lastSeqByChatId).toEqual({ "10": 1, "20": 2 })
      return
    }
    const directoryCalls = () => transport.sent.filter((message) => message.body.oneofKind === "rpcCall"
      && [Method.GET_CHAT_PARTICIPANTS, Method.GET_CHATS].includes(message.body.rpcCall.method))
    if (successfulMiss) {
      const initialCalls = direct ? 1 : 2
      expect(directoryCalls()).toHaveLength(initialCalls)
      now = 999
      expect(await Promise.all(Array.from({ length: 20 }, () =>
        directory.resolveWithProvenance({ userId: 42n, chatId: 10n, direct }))))
        .toEqual(Array.from({ length: 20 }, () => ({ provenanceVerified: false })))
      await Promise.all(Array.from({ length: 20 }, () =>
        directory.resolveWithProvenance({ userId: 41n, chatId: 10n, direct })))
      expect(directoryCalls()).toHaveLength(initialCalls)
      expect(lines.map((line) => JSON.parse(line).chatId)).toEqual(["20"])
      expect(client.exportState().lastSeqByChatId).toEqual({ "10": 1, "20": 2 })
      actorPresent = true
      now = 1_000
      // Exercise the real delivery retry as well as its lookup. No stream ACK
      // occurs while the source is absent; the retry itself fetches the new
      // sender and only verified input reaches Python, without cache pre-seeding.
      await vi.waitFor(() => expect(lines.map((line) => JSON.parse(line).chatId)).toEqual(["20", "10"]), {
        timeout: 2_000, interval: 20,
      })
      expect(directoryCalls()).toHaveLength(initialCalls + 1)
    } else {
      const lookup = transport.sent.find(
        (message) => message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_CHAT_PARTICIPANTS
      )
      expect(lookup).toBeDefined()
      await reply(lookup!.id, {
        oneofKind: "getChatParticipants",
        getChatParticipants: { users: [{ id: 42n, bot: false }] },
      })
    }
    await flush()
    expect(lines.map((line) => JSON.parse(line).chatId)).toEqual(["20", "10"])
    expect(JSON.parse(lines[1]!)).toMatchObject({
      _inlineSenderProvenanceVerified: true,
      sender: { id: "42", firstName: "Jack", bot: false },
    })
    expect(client.exportState().lastSeqByChatId).toEqual({ "10": 1, "20": 2 })
    stream.acknowledge(JSON.parse(lines[1]!)._inlineDeliveryId)
    await flush()
    expect(client.exportState().lastSeqByChatId).toEqual({ "10": 2, "20": 2 })
    expect(lines.map((line) => JSON.parse(line).chatId)).toEqual(["20", "10", "10"])
    expect(JSON.parse(lines[2]!).seq).toBe(3)
    stream.acknowledge(JSON.parse(lines[2]!)._inlineDeliveryId)
    await flush()
    expect(client.exportState().lastSeqByChatId).toEqual({ "10": 3, "20": 2 })
    if (successfulMiss) expect(directoryCalls()).toHaveLength(direct ? 2 : 3)
  } finally {
    abort.abort()
    stream.close()
    await client.close()
    await consuming
  }
})
