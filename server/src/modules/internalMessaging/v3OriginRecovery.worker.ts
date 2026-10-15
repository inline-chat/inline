import { createInterface } from "node:readline"
import { Readable } from "node:stream"
import { makeCandidateHttpApplication } from "@in/server/core/http/candidateApplication"
import { startCoreProductionServer } from "@in/server/core/http/productionHost"
import { closeDb, validateDatabaseStartup } from "@in/server/db"
import { connectionManager } from "@in/server/ws/connections"
import { connectionBackgroundWork } from "@in/server/ws/backgroundWork"
import { connectedUserRepair } from "./repair"

// This process uses the real API, protocol repositories and lifecycle. Only the
// RSA/key-encryption material is synthetic; no auth provider or job is started.
const rsaPrivateKeysJson = process.env["INLINE_TEST_V3_RSA_KEYS"]
if (!rsaPrivateKeysJson) throw new Error("Missing synthetic V3 key ring")
const ring = { activeId: "fixture", keys: new Map([["fixture", new Uint8Array(32).fill(0x71)]]) }
await validateDatabaseStartup()
const host = await startCoreProductionServer({
  application: makeCandidateHttpApplication({ apiBaseUrl: "http://127.0.0.1", middleware: { isProduction: false } }),
  hostname: "127.0.0.1",
  port: 0,
  installSignalHandlers: false,
  startClusterServices: true,
  inlineProtocolConfiguration: {
    enabled: true,
    requireCanonicalPublicRing: false,
    rsaPrivateKeysJson,
    authKeyKekRing: ring,
    authCodePepperRing: ring,
    encryptReplayResults: false,
  },
})
try {
  console.log(`V3_ORIGIN:PORT:${host.port}`)
  for await (const line of createInterface({ input: Readable.fromWeb(Bun.stdin.stream() as never) })) {
    if (line === "STOP") break
    if (line === "ADMISSION_IDLE") {
      await new Promise<void>((resolve) => setTimeout(resolve, 0))
      await connectionBackgroundWork.waitForIdle()
      await connectedUserRepair.waitForIdle()
      console.log("V3_ORIGIN:ADMISSION_IDLE")
    }
    if (line.startsWith("WAIT_REVOKED:")) {
      const sessionId = Number(line.slice("WAIT_REVOKED:".length))
      const deadline = performance.now() + 5_000
      while (connectionManager.getAuthenticatedSessionIdentities().some((session) => session.sessionId === sessionId)) {
        if (performance.now() >= deadline) throw new Error("Revoked session remained admitted on this origin")
        await new Promise<void>((resolve) => setTimeout(resolve, 10))
      }
      console.log("V3_ORIGIN:REVOKED")
    }
  }
} finally {
  await host.shutdown()
  await closeDb()
}
