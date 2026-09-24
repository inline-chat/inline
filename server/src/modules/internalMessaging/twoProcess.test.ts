import { describe, expect, it } from "bun:test"
import { ServerProtocolMessage, type InputPeer } from "@inline-chat/protocol/core"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { internalMessaging } from "./service"
import { db } from "@in/server/db"
import { sql } from "drizzle-orm"
import { connectionManager, ConnVersion } from "@in/server/ws/connections"

const redisUrl = process.env["INLINE_TEST_REDIS_URL"]
if (redisUrl) setupTestLifecycle()

async function* lines(stream: ReadableStream<Uint8Array>): AsyncGenerator<string> {
  const reader = stream.getReader()
  const decoder = new TextDecoder()
  let pending = ""
  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      pending += decoder.decode(value, { stream: true })
      let end: number
      while ((end = pending.indexOf("\n")) >= 0) {
        yield pending.slice(0, end).trimEnd()
        pending = pending.slice(end + 1)
      }
    }
    pending += decoder.decode()
    if (pending) yield pending.trimEnd()
  } finally { reader.releaseLock() }
}

describe("isolated writer and recipient process", () => {
  it.skipIf(!redisUrl)("delivers a committed hint and repairs a silently lost final hint on another process", async () => {
    if (internalMessaging.health !== "ready") await internalMessaging.start()
    const sender = await testUtils.createUser("sender@two-process.test")
    const recipient = await testUtils.createUser("recipient@two-process.test")
    const recipientSession = await testUtils.createSessionForUser(recipient.id)
    const initiatingSession = await testUtils.createSessionForUser(sender.id)
    const otherSenderSession = await testUtils.createSessionForUser(sender.id)
    const chat = await testUtils.createPrivateChat(sender, recipient)
    if (!chat) throw new Error("Expected private chat")
    const [database] = await db.execute<{ name: string }>(sql`SELECT current_database() AS name`)
    if (!database?.name) throw new Error("Test database name is unavailable")
    const childDatabaseUrl = new URL(process.env["TEST_DATABASE_URL"]!)
    childDatabaseUrl.pathname = `/${database.name}`

    const worker = Bun.spawn({
      cmd: [process.execPath, "--no-env-file", "src/modules/internalMessaging/twoProcess.worker.ts"],
      cwd: import.meta.dir + "/../../..",
      env: { ...process.env, DATABASE_URL: childDatabaseUrl.toString(), TEST_DATABASE_URL: childDatabaseUrl.toString(), REDIS_URL: redisUrl!, INLINE_TEST_RECIPIENT_ID: String(recipient.id),
        INLINE_TEST_RECIPIENT_SESSION_ID: String(recipientSession.session.id) },
      stdin: "pipe", stdout: "pipe", stderr: "pipe",
    })
    const ready = Promise.withResolvers<void>()
    const rebuilt = Promise.withResolvers<void>()
    const updates: { chatId: string; seq: number }[] = []
    const initiatingUpdates: string[] = []
    const otherSenderUpdates: string[] = []
    let closeCount = 0
    let updateArrived = Promise.withResolvers<void>()
    let workerOutput = ""
    const consume = (async () => {
      for await (const line of lines(worker.stdout)) {
        if (line === "INLINE_TEST:READY") { workerOutput += "ready\n"; ready.resolve() }
        else if (line === "INLINE_TEST:REBUILT") rebuilt.resolve()
        else if (line === "INLINE_TEST:CLOSED") { closeCount++ }
        else if (line.startsWith("INLINE_TEST:{")) {
          const value = JSON.parse(line.slice("INLINE_TEST:".length)) as { kind: string; chatId: string; seq: number }
          if (value.kind === "chat") {
            updates.push(value)
            updateArrived.resolve()
            updateArrived = Promise.withResolvers<void>()
          }
        } else workerOutput += line.slice(0, 300) + "\n"
      }
    })()
    const consumeErrors = (async () => {
      for await (const line of lines(worker.stderr)) {
        workerOutput += line.slice(0, 300) + "\n"
      }
    })()
    const bounded = async <T>(promise: Promise<T>) => {
      const timeout = Promise.withResolvers<never>()
      const timer = setTimeout(() => timeout.reject(new Error(`Worker did not respond: ${workerOutput}; updates=${JSON.stringify(updates)}`)), 8_000)
      try { return await Promise.race([promise, timeout.promise]) }
      finally { clearTimeout(timer) }
    }
    const waitForSeq = async (minimum: number): Promise<{ chatId: string; seq: number }> => {
      while (true) {
        const found = updates.find((item) => item.seq >= minimum)
        if (found) return found
        await bounded(updateArrived.promise)
      }
    }
    try {
      for (const [id, sessionId, updateKinds] of [
        ["sender:initiating", initiatingSession.session.id, initiatingUpdates],
        ["sender:other", otherSenderSession.session.id, otherSenderUpdates],
      ] as const) {
        const socket = { id, close: () => {}, raw: { sendBinary(bytes: Uint8Array): number {
          const message = ServerProtocolMessage.fromBinary(bytes)
          if (message.body.oneofKind === "message" && message.body.message.payload.oneofKind === "update") {
            for (const update of message.body.message.payload.update.updates) {
              if (update.update.oneofKind) updateKinds.push(update.update.oneofKind)
            }
          }
          return bytes.length
        } } }
        connectionManager.addConnection(socket as never, ConnVersion.REALTIME_V1)
        connectionManager.authenticateConnection(id, sender.id, sessionId, 2, false, "web")
      }
      await bounded(ready.promise)
      worker.stdin.write("REBUILD\n")
      await bounded(rebuilt.promise)
      const peer: InputPeer = { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } }
      const first = await sendMessage({ peerId: peer, message: "Cross-process durable message", randomId: 8787n },
        testUtils.functionContext({ userId: sender.id, sessionId: initiatingSession.session.id }))
      expect(first.updates.map((update) => update.update.oneofKind)).toEqual(["updateMessageId", "newMessage"])
      expect(initiatingUpdates).not.toContain("updateMessageId")
      expect(initiatingUpdates).not.toContain("newMessage")
      expect(otherSenderUpdates.filter((kind) => kind === "updateMessageId" || kind === "newMessage"))
        .toEqual(["updateMessageId", "newMessage"])
      expect(await waitForSeq(1)).toMatchObject({ chatId: String(chat.id), seq: 1 })
      await sendMessage({ peerId: peer, message: "Cross-process durable message", randomId: 8787n },
        testUtils.functionContext({ userId: sender.id, sessionId: initiatingSession.session.id }))
      const afterRetry = await db.query.chats.findFirst({ where: { id: chat.id }, columns: { updateSeq: true } })
      expect(afterRetry?.updateSeq).toBe(1)
      // A user-bucket reference can accompany the message. Its current
      // record now replays under the existing protocol; a healthy transport
      // must not be disconnected simply because the account sequence moved.
      // The writer still commits when the broker is unavailable. The periodic
      // durable scan repairs the quiet chat's final lost hint.
      await internalMessaging.close()
      await sendMessage({ peerId: peer, message: "Recovered without publication", randomId: 8788n },
        testUtils.functionContext({ userId: sender.id, sessionId: initiatingSession.session.id }))
      const currentChat = await db.query.chats.findFirst({ where: { id: chat.id }, columns: { updateSeq: true } })
      expect(currentChat?.updateSeq).toBe(2)
      worker.stdin.write("SCAN\n")
      expect(await waitForSeq(2)).toMatchObject({ chatId: String(chat.id), seq: 2 })
      expect(closeCount).toBe(0)
    } finally {
      connectionManager.closeConnection("sender:initiating")
      connectionManager.closeConnection("sender:other")
      worker.stdin.write("STOP\n")
      worker.stdin.end()
      await Promise.race([worker.exited, Bun.sleep(2_000).then(() => { worker.kill("SIGTERM") })])
      await consume
      await consumeErrors
      await internalMessaging.close()
    }
  }, 15_000)
})
