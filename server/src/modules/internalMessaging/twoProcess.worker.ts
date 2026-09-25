import { ServerProtocolMessage } from "@inline-chat/protocol/core"
import { closeDb } from "@in/server/db"
import { connectionManager, ConnVersion } from "@in/server/ws/connections"
import { connectionBackgroundWork } from "@in/server/ws/backgroundWork"
import { connectionDirectory } from "./directory"
import { connectedUserRepair } from "./repair"
import { createInterface } from "node:readline"
import { Readable } from "node:stream"
import { Layer } from "effect"
import { HttpRouter } from "effect/unstable/http"
import { startCoreProductionServer } from "@in/server/core/http/productionHost"
import { makeHttpKernelMiddlewareLayer } from "@in/server/core/http/middleware"
import { executeReadiness } from "@in/server/controllers/health.effect"
import { HealthOperationsLive } from "@in/server/controllers/healthLive.effect"

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

// Use the actual production startup, readiness and shutdown owners. The
// recipient socket below records real encoded frames without a client runtime.
const application = Layer.effectDiscard(HttpRouter.HttpRouter.use((router) =>
  router.add("GET", "/readyz", executeReadiness),
)).pipe(
  Layer.provideMerge(HealthOperationsLive),
  Layer.provideMerge(makeHttpKernelMiddlewareLayer({ isProduction: false })),
)
let host: Awaited<ReturnType<typeof startCoreProductionServer>> | undefined
try {
  host = await startCoreProductionServer({
    application,
    hostname: "127.0.0.1",
    inlineProtocolConfiguration: { enabled: false },
    startClusterServices: true,
  })
  const ready = await fetch(`http://127.0.0.1:${host.port}/readyz`)
  const readiness = await ready.json() as { ok: boolean; checks: { broker: { ok: boolean } } }
  if (ready.status !== 200 || !readiness.ok) {
    throw new Error(`Production host did not become ready: HTTP ${ready.status} ${JSON.stringify(readiness)}`)
  }
  console.log(`INLINE_TEST:BROKER:${readiness.checks.broker.ok ? "ready" : "unavailable"}`)
  connectionManager.addConnection(socket as never, ConnVersion.REALTIME_V1)
  connectionManager.authenticateConnection(connectionId, userId, sessionId, 2, false, "web")
  // Authentication schedules its repair admission on a zero-delay timer.
  // Cross that timer turn before joining it, so startup cannot repair the
  // later test message and masquerade as periodic recovery.
  await new Promise<void>((resolve) => setTimeout(resolve, 0))
  await connectionBackgroundWork.waitForIdle()
  await connectedUserRepair.waitForIdle()
  console.log("INLINE_TEST:READY")
  for await (const line of createInterface({ input: Readable.fromWeb(Bun.stdin.stream() as never) })) {
    if (line.trim() === "STOP") break
    if (line.trim() === "SCAN") connectedUserRepair.observe(userId)
    if (line.trim() === "REBUILD") {
      await connectionDirectory.rebuild()
      await connectedUserRepair.waitForIdle()
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
  await host?.shutdown()
  await closeDb()
}
