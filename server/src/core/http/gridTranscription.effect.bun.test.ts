import { expect, test } from "bun:test"
import { makeCandidateHttpApplication } from "./candidateApplication"
import { gridTranscriptionWorkerPaths } from "./gridTranscription.effect"
import { startCoreHttpServer } from "./host"

test("production application mounts every internal transcription action with a closed default gate", async () => {
  const host = await startCoreHttpServer({
    application: makeCandidateHttpApplication({ middleware: { isProduction: false } }),
    hostname: "127.0.0.1",
    installSignalHandlers: false,
  })
  try {
    for (const path of gridTranscriptionWorkerPaths) {
      const response = await fetch(`http://127.0.0.1:${host.port}${path}`, {
        method: "POST",
        body: JSON.stringify({ workerId: "untrusted-worker" }),
        headers: { "content-type": "application/json" },
      })
      expect(response.status).toBe(503)
      expect(response.headers.get("cache-control")).toBe("no-store")
      expect(await response.json()).toEqual({ error: "unavailable" })
    }
  } finally {
    await host.shutdown()
  }
})
