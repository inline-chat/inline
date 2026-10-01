import { createInterface } from "node:readline"
import { Readable } from "node:stream"
import { makeCandidateHttpApplication } from "@in/server/core/http/candidateApplication"
import { startCoreProductionServer } from "@in/server/core/http/productionHost"
import { closeDb } from "@in/server/db"
import { connectionBackgroundWork } from "@in/server/ws/backgroundWork"
import { connectedUserRepair } from "./repair"

// A separate API process with the real authenticated WebSocket/RPC graph.
// No workers or public listeners: this fixture shares only its disposable DB.
const host = await startCoreProductionServer({
  application: makeCandidateHttpApplication({ apiBaseUrl: "http://127.0.0.1", middleware: { isProduction: false } }),
  hostname: "127.0.0.1",
  port: 0,
  installSignalHandlers: false,
  startClusterServices: true,
  inlineProtocolConfiguration: { enabled: false },
})
try {
  console.log(`SOCKET_RECOVERY:PORT:${host.port}`)
  for await (const line of createInterface({ input: Readable.fromWeb(Bun.stdin.stream() as never) })) {
    if (line === "STOP") break
    if (line === "ADMISSION_IDLE") {
      // Join authentication's zero-delay work; never trigger a manual scan.
      await new Promise<void>((resolve) => setTimeout(resolve, 0))
      await connectionBackgroundWork.waitForIdle()
      await connectedUserRepair.waitForIdle()
      console.log("SOCKET_RECOVERY:ADMISSION_IDLE")
    }
  }
} finally {
  await host.shutdown()
  await closeDb()
}
