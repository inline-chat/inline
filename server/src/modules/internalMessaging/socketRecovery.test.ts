import { expect, test } from "bun:test"
import { createInterface } from "node:readline"
import { Readable } from "node:stream"
import { ClientMessage, GetUpdatesResult_ResultType, Method, ServerProtocolMessage, type GetUpdatesResult, type Update } from "@inline-chat/protocol/core"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { sql } from "drizzle-orm"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { editMessage } from "@in/server/functions/messages.editMessage"
import { deleteMessage } from "@in/server/functions/messages.deleteMessage"
import { internalMessaging } from "./service"
import { liveRealtimeDelivery } from "./liveDelivery"

setupTestLifecycle()

const bounded = async <T>(operation: Promise<T>, label: string, milliseconds = 8_000): Promise<T> => {
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([operation, new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`Timed out: ${label}`)), milliseconds)
    })])
  } finally { clearTimeout(timer) }
}

test("a remote authenticated socket applies message/edit/delete and sidecars through GET_UPDATES after publication stops", async () => {
  const previousMode = process.env["REALTIME_DISTRIBUTED"]
  process.env["REALTIME_DISTRIBUTED"] = "1"
  // Fault injection removes both full-payload delivery and legacy hints. The
  // recipient must discover the committed frontier through PostgreSQL alone.
  await liveRealtimeDelivery.stop()
  await internalMessaging.close()
  const sender = await testUtils.createUser("socket-recovery-sender@test.invalid")
  const recipient = await testUtils.createUser("socket-recovery-recipient@test.invalid")
  const { token } = await testUtils.createSessionForUser(recipient.id, { clientType: "cli" })
  const chat = await testUtils.createPrivateChat(sender, recipient)
  if (!chat) throw new Error("Expected DM")
  const [database] = await db.execute<{ name: string }>(sql`SELECT current_database() AS name`)
  if (!database) throw new Error("Missing isolated database")
  const databaseUrl = new URL(process.env["TEST_DATABASE_URL"]!)
  databaseUrl.pathname = `/${database.name}`
  const worker = Bun.spawn({
    cmd: [process.execPath, "--no-env-file", "src/modules/internalMessaging/socketRecovery.worker.ts"],
    cwd: import.meta.dir + "/../../..",
    env: { ...process.env, DATABASE_URL: databaseUrl.toString(), TEST_DATABASE_URL: databaseUrl.toString(),
      REDIS_URL: "", VALKEY_URL: "", REALTIME_DISTRIBUTED: "1", PORT: "0" },
    stdin: "pipe", stdout: "pipe", stderr: "pipe",
  })
  const port = Promise.withResolvers<number>()
  const admissionIdle = Promise.withResolvers<void>()
  let workerOutput = ""
  const readOutput = async (stream: ReadableStream<Uint8Array>) => {
    for await (const line of createInterface({
      input: Readable.fromWeb(stream as never),
    })) {
      if (line.startsWith("SOCKET_RECOVERY:PORT:")) port.resolve(Number(line.split(":").at(-1)))
      else if (line === "SOCKET_RECOVERY:ADMISSION_IDLE") admissionIdle.resolve()
      else workerOutput = (workerOutput + line + "\n").slice(-8_000)
    }
  }
  const readers = Promise.all([readOutput(worker.stdout), readOutput(worker.stderr)])
  let socket: WebSocket | undefined
  let recovery = Promise.resolve()
  const errors: unknown[] = []
  const pending = new Map<bigint, ReturnType<typeof Promise.withResolvers<GetUpdatesResult>>>()
  const model = new Map<bigint, string>()
  const users = new Set<bigint>()
  const applied: string[] = []
  let seq = 0n
  let requestId = 10n
  let closeCount = 0
  let recoveryPages = 0
  let changed = Promise.withResolvers<void>()
  const signal = () => { changed.resolve(); changed = Promise.withResolvers<void>() }
  const apply = (update: Update) => {
    const value = update.update
    if (value.oneofKind === "newMessage" || value.oneofKind === "editMessage") {
      const message = value.oneofKind === "newMessage" ? value.newMessage.message : value.editMessage.message
      if (!message) throw new Error("Missing recovered message")
      // Sidecars must be applied before the dependent message, not fetched by
      // a separate helper which could hide an incomplete getUpdates result.
      if (!users.has(message.fromId)) throw new Error("Sender sidecar not applied before message")
      model.set(message.id, message.message ?? "")
      applied.push(value.oneofKind)
    } else if (value.oneofKind === "deleteMessages") {
      for (const id of value.deleteMessages.messageIds) model.delete(id)
      applied.push(value.oneofKind)
    }
  }
  const waitUntil = async (predicate: () => boolean) => {
    await bounded((async () => {
      while (!predicate()) {
        if (errors.length) throw new AggregateError(errors, "Socket recovery failed")
        await changed.promise
      }
    })(), `client convergence; ${workerOutput}`, 5_000)
  }
  try {
    socket = new WebSocket(`ws://127.0.0.1:${await bounded(port.promise, "remote startup")}/realtime`)
    socket.binaryType = "arraybuffer"
    const opened = Promise.withResolvers<void>()
    const authenticated = Promise.withResolvers<void>()
    socket.addEventListener("open", () => opened.resolve(), { once: true })
    socket.addEventListener("close", () => { closeCount++; signal() })
    socket.addEventListener("error", () => { errors.push(new Error("WebSocket error")); signal() })
    socket.addEventListener("message", ({ data }) => {
      try {
        const frame = ServerProtocolMessage.fromBinary(new Uint8Array(data as ArrayBuffer))
        if (frame.body.oneofKind === "connectionOpen") authenticated.resolve()
        if (frame.body.oneofKind === "rpcError") throw new Error(`RPC failed: ${frame.body.rpcError.code}`)
        if (frame.body.oneofKind === "rpcResult" && frame.body.rpcResult.result.oneofKind === "getUpdates") {
          pending.get(frame.body.rpcResult.reqMsgId)?.resolve(frame.body.rpcResult.result.getUpdates)
          pending.delete(frame.body.rpcResult.reqMsgId)
        }
        if (frame.body.oneofKind !== "message" || frame.body.message.payload.oneofKind !== "update") return
        for (const update of frame.body.message.payload.update.updates) {
          if (update.update.oneofKind !== "chatHasNewUpdates" || update.update.chatHasNewUpdates.chatId !== BigInt(chat.id)) continue
          const hint = update.update.chatHasNewUpdates
          recovery = recovery.then(async () => {
            while (seq < BigInt(hint.updateSeq)) {
              const id = requestId++
              const response = Promise.withResolvers<GetUpdatesResult>()
              pending.set(id, response)
              socket!.send(Uint8Array.from(ClientMessage.toBinary({ id, seq: Number(id), body: { oneofKind: "rpcCall", rpcCall: {
                method: Method.GET_UPDATES, input: { oneofKind: "getUpdates", getUpdates: {
                  bucket: { type: { oneofKind: "chat", chat: { peerId: hint.peerId } } },
                  startSeq: seq, seqEnd: 0n, limit: 1, totalLimit: 0,
                } },
              } } })).buffer)
              const page = await bounded(response.promise, "GET_UPDATES")
              expect(page.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
              expect(page.seq).toBeGreaterThan(seq)
              for (const user of page.sidecars?.users ?? []) users.add(user.id)
              for (const recovered of page.updates) apply(recovered)
              seq = page.seq
              recoveryPages++
              signal()
            }
          }).catch((error: unknown) => { errors.push(error); signal() })
        }
      } catch (error) { errors.push(error); signal() }
    })
    await bounded(opened.promise, "socket open")
    socket.send(Uint8Array.from(ClientMessage.toBinary({ id: 1n, seq: 1, body: { oneofKind: "connectionInit", connectionInit: {
      token, layer: 2, clientVersion: "1.0.0",
    } } })).buffer)
    await bounded(authenticated.promise, "authentication")
    worker.stdin.write("ADMISSION_IDLE\n")
    await bounded(admissionIdle.promise, "initial repair admission")
    const peer = { type: { oneofKind: "chat" as const, chat: { chatId: BigInt(chat.id) } } }
    const context = testUtils.functionContext({ userId: sender.id })
    const sent = await sendMessage({ peerId: peer, message: "Recovered from PostgreSQL", randomId: 691n }, context)
    const message = sent.updates.find((update) => update.update.oneofKind === "newMessage")
    if (message?.update.oneofKind !== "newMessage" || !message.update.newMessage.message) throw new Error("Missing sent message")
    const messageId = message.update.newMessage.message.id
    await waitUntil(() => model.get(messageId) === "Recovered from PostgreSQL")
    expect(users.has(BigInt(sender.id))).toBe(true)
    await editMessage({ messageId, peer, text: "Recovered edit" }, context)
    await waitUntil(() => model.get(messageId) === "Recovered edit")
    await deleteMessage({ messageIds: [messageId], peer }, context)
    await waitUntil(() => !model.has(messageId))
    expect(applied).toEqual(["newMessage", "editMessage", "deleteMessages"])
    expect(recoveryPages).toBe(3)
    expect(seq).toBe(3n)
    expect(closeCount).toBe(0)
    expect(errors).toEqual([])
  } finally {
    socket?.close()
    for (const request of pending.values()) request.reject(new Error("Test client closed"))
    pending.clear()
    await recovery
    worker.stdin.write("STOP\n")
    worker.stdin.end()
    try { expect(await bounded(worker.exited, `worker shutdown; ${workerOutput}`)).toBe(0) }
    finally {
      if (worker.exitCode === null) { worker.kill("SIGTERM"); await worker.exited }
      await readers
      if (previousMode === undefined) delete process.env["REALTIME_DISTRIBUTED"]
      else process.env["REALTIME_DISTRIBUTED"] = previousMode
    }
  }
}, 30_000)
