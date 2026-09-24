import { ServerProtocolMessage } from "@inline-chat/protocol/core"
import { closeDb } from "@in/server/db"
import { connectionManager, ConnVersion } from "@in/server/ws/connections"
import { connectionDirectory } from "./directory"
import { connectedUserRepair } from "./repair"
import { internalMessaging } from "./service"
import { createInterface } from "node:readline"
import { Readable } from "node:stream"

const userId = Number(process.env["INLINE_TEST_RECIPIENT_ID"])
const sessionId = Number(process.env["INLINE_TEST_RECIPIENT_SESSION_ID"])
if (!Number.isSafeInteger(userId) || !Number.isSafeInteger(sessionId)) throw new Error("Missing isolated recipient identity")

const connectionId = `test-worker:${process.pid}`
const socket = {
  id: connectionId,
  close: () => { console.log("INLINE_TEST:CLOSED") },
  raw: {
    sendBinary(bytes: Uint8Array): number {
      const message = ServerProtocolMessage.fromBinary(bytes)
      if (message.body.oneofKind === "message" && message.body.message.payload.oneofKind === "update") {
        for (const update of message.body.message.payload.update.updates) {
          if (update.update.oneofKind === "chatHasNewUpdates") {
            console.log(`INLINE_TEST:${JSON.stringify({ kind: "chat", chatId: String(update.update.chatHasNewUpdates.chatId), seq: update.update.chatHasNewUpdates.updateSeq })}`)
          }
        }
      }
      return bytes.length
    },
  },
}

connectionDirectory.resume()
const unsubscribe = internalMessaging.on("DurableUpdatesAvailable", ({ event }) => {
  return connectedUserRepair.observeBucket(event)
})
try {
  await internalMessaging.start()
  await connectedUserRepair.start()
  connectionManager.addConnection(socket as never, ConnVersion.REALTIME_V1)
  connectionManager.authenticateConnection(connectionId, userId, sessionId, 2, false, "web")
  console.log("INLINE_TEST:READY")
  for await (const line of createInterface({ input: Readable.fromWeb(Bun.stdin.stream() as never) })) {
    if (line.trim() === "STOP") break
    if (line.trim() === "SCAN") connectedUserRepair.observe(userId)
    if (line.trim() === "REBUILD") {
      await connectionDirectory.rebuild()
      console.log("INLINE_TEST:REBUILT")
    }
    if (line.trim() === "RECONNECT") {
      const nextId = `${connectionId}:again`
      connectionManager.addConnection({ ...socket, id: nextId } as never, ConnVersion.REALTIME_V1)
      connectionManager.authenticateConnection(nextId, userId, sessionId, 2, false, "web")
      console.log("INLINE_TEST:RECONNECTED")
    }
  }
} finally {
  unsubscribe()
  await connectionManager.shutdown()
  await connectedUserRepair.stop()
  await connectionDirectory.shutdown()
  await internalMessaging.close()
  await closeDb()
}
