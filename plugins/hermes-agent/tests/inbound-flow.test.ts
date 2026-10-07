import { PassThrough, Readable } from "node:stream"
import { expect, it } from "vitest"
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

it.each([
  { kind: "newMessage", serviceKind: "threadBacklink" },
  { kind: "editMessage", serviceKind: "threadBacklink" },
  { kind: "newMessage", serviceKind: "pinnedMessage" },
  { kind: "editMessage", serviceKind: "pinnedMessage" },
] as const)("service $kind $serviceKind advances SDK receipt before the same-chat human ACK", async ({ kind, serviceKind }) => {
  const { client, transport } = createWireClient()
  const stream = new InboundStream()
  const consumer = new PassThrough()
  const lines: string[] = []
  consumer.on("data", (chunk) => lines.push(chunk.toString()))
  stream.attach(consumer)
  const abort = new AbortController()
  let consuming: Promise<void> | undefined
  let senderLookups = 0
  try {
    const connecting = client.connect()
    await flush()
    await transport.connect()
    await flush()
    await transport.emitMessage(ServerProtocolMessage.create({ body: { oneofKind: "connectionOpen", connectionOpen: {} } }))
    await connecting
    consuming = client.consumeEvents((event) => deliverInboundEvent(event, {
      meId: "777", meUsername: "bot", signal: abort.signal,
      resolveSender: async () => {
        senderLookups++
        return { profile: { id: "42", bot: false }, provenanceVerified: true }
      },
      deliver: (event) => stream.deliver(event),
    }))
    const servicePayload = serviceKind === "threadBacklink"
      ? { event: { oneofKind: "threadBacklink" as const, threadBacklink: { sourceChatId: 99n } } }
      : { event: { oneofKind: "pinnedMessage" as const, pinnedMessage: { messageId: 3n } } }
    const message = (seq: number, service: boolean) => ({
      id: BigInt(seq), chatId: 10n, fromId: 42n, date: 100n,
      message: "Pinned a message · Reply in thread",
      peerId: { type: { oneofKind: "chat" as const, chat: { chatId: 10n } } },
      entities: { entities: service ? [{ offset: 0, length: 4, entity: { oneofKind: "mention" as const, mention: { userId: 777n } } }] : [] },
      ...(service ? { serviceMessage: servicePayload } : {}),
    })
    const service = kind === "newMessage"
      ? Update.create({ seq: 2, date: 100n, update: { oneofKind: "newMessage", newMessage: { message: message(2, true) } } })
      : Update.create({ seq: 2, date: 100n, update: { oneofKind: "editMessage", editMessage: { message: message(2, true) } } })
    const payload = ServerProtocolMessage.create({ body: { oneofKind: "message", message: {
      payload: { oneofKind: "update", update: { updates: [service,
        Update.create({ seq: 3, date: 100n, update: { oneofKind: "newMessage", newMessage: { message: message(3, false) } } }),
      ] } },
    } } })
    const decoded = ServerProtocolMessage.fromBinary(ServerProtocolMessage.toBinary(payload))
    // Prove the actual typed oneof survived encoding before asserting intake.
    expect(decoded).toMatchObject({ body: { message: { payload: { update: { updates: [
      { update: { [kind]: { message: { serviceMessage: servicePayload } } } }, {},
    ] } } } } })
    await transport.emitMessage(decoded)
    await flush()
    expect(lines).toHaveLength(1)
    expect(senderLookups).toBe(1)
    const human = JSON.parse(lines[0]!)
    expect(human).toMatchObject({ chatId: "10", seq: 3, message: { message: "Pinned a message · Reply in thread" } })
    expect(client.exportState().lastSeqByChatId).toEqual({ "10": 2, "20": 1 })
    stream.acknowledge(human._inlineDeliveryId)
    await flush()
    expect(client.exportState().lastSeqByChatId).toEqual({ "10": 3, "20": 1 })
  } finally {
    abort.abort()
    stream.close()
    await client.close()
    await consuming
  }
})

function createWireClient() {
  // Script only the remote wire; all SDK, directory and delivery objects are real.
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
  }
  const client = new InlineSdkClient({
    token: "test",
    transport,
    state: {
      load: async () => ({ version: 1, lastSeqByChatId: { "10": 1, "20": 1 } }),
      save: async () => {},
    },
  })
  return { client, transport, reply }
}

it.each(["recover", "abort"])("real SDK, directory and stream isolate held sender lookup across %s", async action => {
  const { client, transport, reply } = createWireClient()
  const directory = new InlineUserDirectory(client)
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
    consuming = client.consumeEvents(async (event) =>
      deliverInboundEvent(event, {
        meId: "777",
        meUsername: "bot",
        signal: abort.signal,
        resolveSender: (event) =>
          directory.resolveWithProvenance({ userId: 42n, chatId: BigInt(event.chatId as bigint), direct: false }),
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
              peerId: { type: { oneofKind: "chat", chat: { chatId } } },
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
    const lookup = transport.sent.find(
      (message) => message.body.oneofKind === "rpcCall" && message.body.rpcCall.method === Method.GET_CHAT_PARTICIPANTS
    )
    expect(lookup).toBeDefined()
    await reply(lookup!.id, {
      oneofKind: "getChatParticipants",
      getChatParticipants: { users: [{ id: 42n, bot: false }] },
    })
    await flush()
    expect(lines.map((line) => JSON.parse(line).chatId)).toEqual(["20", "10"])
    expect(client.exportState().lastSeqByChatId).toEqual({ "10": 1, "20": 2 })
    stream.acknowledge(JSON.parse(lines[1]!)._inlineDeliveryId)
    await flush()
    expect(client.exportState().lastSeqByChatId).toEqual({ "10": 2, "20": 2 })
    expect(lines.map((line) => JSON.parse(line).chatId)).toEqual(["20", "10", "10"])
    expect(JSON.parse(lines[2]!).seq).toBe(3)
    stream.acknowledge(JSON.parse(lines[2]!)._inlineDeliveryId)
    await flush()
    expect(client.exportState().lastSeqByChatId).toEqual({ "10": 3, "20": 2 })
  } finally {
    abort.abort()
    stream.close()
    await client.close()
    await consuming
  }
})
