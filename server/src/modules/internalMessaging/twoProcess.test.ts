import { describe, expect, it } from "bun:test"
import { ServerProtocolMessage, type InputPeer } from "@inline-chat/protocol/core"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { liveRealtimeDelivery } from "./liveDelivery"
import { editMessage } from "@in/server/functions/messages.editMessage"
import { addReaction } from "@in/server/functions/messages.addReaction"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { internalMessaging } from "./service"
import { db } from "@in/server/db"
import { sql } from "drizzle-orm"
import { connectionManager, ConnVersion } from "@in/server/ws/connections"

const redisUrl = process.env["INLINE_TEST_REDIS_URL"]
setupTestLifecycle()

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
  for (const broker of [
    { name: "a working broker", url: redisUrl ?? "", enabled: Boolean(redisUrl), replicas: 1 },
    { name: "four API processes during deployment overlap", url: redisUrl ?? "", enabled: Boolean(redisUrl), replicas: 3 },
    { name: "no configured broker", url: "", enabled: true, replicas: 1 },
    { name: "an unavailable broker", url: "redis://127.0.0.1:1", enabled: true, replicas: 1 },
  ]) {
    it.skipIf(!broker.enabled)(`delivers and repairs committed updates on another process with ${broker.name}`, async () => {
      process.env["REALTIME_DISTRIBUTED"] = "1"
      liveRealtimeDelivery.start()
      if (broker.url === redisUrl && redisUrl) await internalMessaging.start()
      else await internalMessaging.close()
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

      const workers = Array.from({ length: broker.replicas }, () => Bun.spawn({
        cmd: [process.execPath, "--no-env-file", "src/modules/internalMessaging/twoProcess.worker.ts"],
        cwd: import.meta.dir + "/../../..",
        env: { ...process.env, DATABASE_URL: childDatabaseUrl.toString(), TEST_DATABASE_URL: childDatabaseUrl.toString(), REDIS_URL: broker.url, VALKEY_URL: "", REALTIME_DISTRIBUTED: "1", INLINE_TEST_RECIPIENT_ID: String(recipient.id),
          INLINE_TEST_RECIPIENT_SESSION_ID: String(recipientSession.session.id) },
        stdin: "pipe", stdout: "pipe", stderr: "pipe",
      }))
      const worker = workers[0]!
      const ready = Promise.withResolvers<void>()
      const rebuilt = Promise.withResolvers<void>()
      const updates: { kind: string; updateKind?: string; text?: string; chatId: string; seq: number }[] = []
      const allUpdates: (typeof updates)[] = workers.map(() => [])
      const readyWorkers = new Set<number>()
      const initiatingUpdates: string[] = []
      const otherSenderUpdates: string[] = []
      let closeCount = 0
      let brokerHealth: string | undefined
      let updateArrived = Promise.withResolvers<void>()
      let workerOutput = ""
      const consume = Promise.all(workers.map(async (source, index) => {
        for await (const line of lines(source.stdout)) {
          if (line === "INLINE_TEST:READY") { readyWorkers.add(index); if (readyWorkers.size === workers.length) ready.resolve() }
          else if (line === "INLINE_TEST:REBUILT") rebuilt.resolve()
          else if (line.startsWith("INLINE_TEST:BROKER:")) brokerHealth = line.slice("INLINE_TEST:BROKER:".length)
          else if (line === "INLINE_TEST:CLOSED") { closeCount++ }
          else if (line.startsWith("INLINE_TEST:{")) {
            const value = JSON.parse(line.slice("INLINE_TEST:".length)) as typeof updates[number]
            if (value.kind === "chat" || value.kind === "live") {
              allUpdates[index]!.push(value)
              if (index === 0) updates.push(value)
              updateArrived.resolve()
              updateArrived = Promise.withResolvers<void>()
            }
          } else workerOutput += line.slice(0, 300) + "\n"
        }
      }))
      const consumeErrors = Promise.all(workers.map(async (source) => {
        for await (const line of lines(source.stderr)) {
          workerOutput += line.slice(0, 300) + "\n"
        }
      }))
      const bounded = async <T>(promise: Promise<T>, timeoutMs = 8_000) => {
        const timeout = Promise.withResolvers<never>()
        const timer = setTimeout(() => timeout.reject(new Error(`Worker did not respond: ${workerOutput}; updates=${JSON.stringify(updates)}`)), timeoutMs)
        try { return await Promise.race([promise, timeout.promise]) }
        finally { clearTimeout(timer) }
      }
      const waitForSeq = async (minimum: number): Promise<{ chatId: string; seq: number }> => {
        while (true) {
          const found = updates.find((item) => item.seq >= minimum)
          if (found) return found
          await bounded(updateArrived.promise, 4_900)
        }
      }
      const waitForAll = async (seq: number) => {
        while (!allUpdates.every((events) => events.some((event) => event.seq >= seq))) await bounded(updateArrived.promise, 4_900)
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
        expect(brokerHealth).toBe(broker.url === redisUrl && redisUrl ? "ready" : "unavailable")
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
        // No manual SCAN: configured multi-server mode must discover a missed
        // publication even with no broker and no later traffic.
        expect(await waitForSeq(1)).toMatchObject({ chatId: String(chat.id), seq: 1 })
        await sendMessage({ peerId: peer, message: "Cross-process durable message", randomId: 8787n },
          testUtils.functionContext({ userId: sender.id, sessionId: initiatingSession.session.id }))
        const afterRetry = await db.query.chats.findFirst({ where: { id: chat.id }, columns: { updateSeq: true } })
        expect(afterRetry?.updateSeq).toBe(1)
        if (broker.url === redisUrl && redisUrl) {
          await waitForAll(1)
          for (const events of allUpdates) expect(events.find((item) => item.seq === 1)).toMatchObject({ kind: "live", updateKind: "newMessage", text: "Cross-process durable message" })
          const message = first.updates.find((u) => u.update.oneofKind === "newMessage")
          if (message?.update.oneofKind !== "newMessage" || !message.update.newMessage.message) throw new Error("Missing message")
          const messageId = message.update.newMessage.message.id
          const editedAt = Date.now()
          await editMessage({ messageId, peer, text: "Edited across processes" }, testUtils.functionContext({ userId: sender.id, sessionId: initiatingSession.session.id }))
          expect(await waitForSeq(2)).toMatchObject({ kind: "live", updateKind: "editMessage", text: "Edited across processes" })
          await waitForAll(2)
          expect(Date.now() - editedAt).toBeLessThan(1_000)
          await addReaction({ messageId, peer, emoji: "👍" }, testUtils.functionContext({ userId: sender.id, sessionId: initiatingSession.session.id }))
          while (!updates.some((u) => u.updateKind === "updateReaction")) await bounded(updateArrived.promise, 1_000)
          const receivedBefore = otherSenderUpdates.filter((kind) => kind === "newMessage").length
          worker.stdin.write(`SEND:${JSON.stringify({ chatId: chat.id, text: "From the other server" })}\n`)
          const reverseDeadline = Date.now() + 1_000
          while (otherSenderUpdates.filter((kind) => kind === "newMessage").length === receivedBefore && Date.now() < reverseDeadline) {
            await new Promise((resolve) => setTimeout(resolve, 10))
          }
          expect(otherSenderUpdates.filter((kind) => kind === "newMessage").length).toBe(receivedBefore + 1)
          await new Promise((resolve) => setTimeout(resolve, 1_500))
          for (const events of allUpdates) expect(events.filter((u) => u.kind === "chat")).toHaveLength(0)
        }
        // A user-bucket reference can accompany the message. Its current
        // record now replays under the existing protocol; a healthy transport
        // must not be disconnected simply because the account sequence moved.
        // The writer still commits when the broker is unavailable. The periodic
        // durable scan repairs the quiet chat's final lost hint.
        const beforeOutage = await db.query.chats.findFirst({ where: { id: chat.id }, columns: { updateSeq: true } })
        const outageSeq = (beforeOutage?.updateSeq ?? 0) + 1
        await internalMessaging.close()
        const recoveryStarted = Date.now()
        await sendMessage({ peerId: peer, message: "Recovered without publication", randomId: 8788n },
          testUtils.functionContext({ userId: sender.id, sessionId: initiatingSession.session.id }))
        const currentChat = await db.query.chats.findFirst({ where: { id: chat.id }, columns: { updateSeq: true } })
        expect(currentChat?.updateSeq).toBe(outageSeq)
        expect(await waitForSeq(outageSeq)).toMatchObject({ kind: "chat", chatId: String(chat.id), seq: outageSeq })
        await waitForAll(outageSeq)
        expect(Date.now() - recoveryStarted).toBeLessThan(5_000)
        expect(closeCount).toBe(0)
      } finally {
        connectionManager.closeConnection("sender:initiating")
        connectionManager.closeConnection("sender:other")
        for (const source of workers) { source.stdin.write("STOP\n"); source.stdin.end() }
        try {
          expect(await bounded(Promise.all(workers.map((source) => source.exited)))).toEqual(workers.map(() => 0))
        } finally {
          for (const source of workers) {
            if (source.exitCode === null) { source.kill("SIGTERM"); await source.exited }
          }
          await consume
          await consumeErrors
          await liveRealtimeDelivery.stop()
          await internalMessaging.close()
          delete process.env["REALTIME_DISTRIBUTED"]
        }
      }
    }, 50_000)
  }
})
