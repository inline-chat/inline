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

it.each(["recover", "abort"])("real SDK, directory and stream isolate held sender lookup across %s", async action => {
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
    const message = (chatId: bigint, mention: boolean) =>
      Update.create({
        seq: 2,
        date: 100n,
        update: {
          oneofKind: "newMessage",
          newMessage: {
            message: {
              id: 2n,
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
            payload: { oneofKind: "update", update: { updates: [message(10n, false), message(20n, true)] } },
          },
        },
      })
    )
    await flush()
    expect(lines.map((line) => JSON.parse(line).chatId)).toEqual(["20"])
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
    expect(client.exportState().lastSeqByChatId).toEqual({ "10": 2, "20": 2 })
  } finally {
    abort.abort()
    stream.close()
    await client.close()
    await consuming
  }
})
