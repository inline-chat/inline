import { describe, expect, test } from "bun:test"
import { execFileSync, fork } from "node:child_process"
import { createServer } from "node:http"
import { fileURLToPath } from "node:url"
import { workerConfig } from "./daemon.js"

const nodeExecutable = execFileSync(process.env.GRID_TRANSCRIPTION_TEST_NODE ?? "node", ["--print", "process.execPath"], { encoding: "utf8" }).trim()
let compiled = false
function ensureCompiled(): void {
  if (compiled) return
  execFileSync(nodeExecutable, [fileURLToPath(new URL("../node_modules/typescript/bin/tsc", import.meta.url)), "-p", "tsconfig.json"], {
    cwd: fileURLToPath(new URL("..", import.meta.url)), env: {}, encoding: "utf8",
  })
  execFileSync(nodeExecutable, [fileURLToPath(new URL("../dist/copy-model.js", import.meta.url))], { env: {}, encoding: "utf8" })
  compiled = true
}
async function noChildClaimFixture(mode: "delayed" | "lost" | "retry_stopped") {
  ensureCompiled()
  let daemon: ReturnType<typeof fork> | undefined
  let claims = 0
  let stops = 0
  let acknowledged = false
  let prematureExit = false
  let readyFalse = false
  const workers: string[] = []
  const server = createServer(async (request, response) => {
    let body = ""
    for await (const chunk of request) body += chunk
    const value = JSON.parse(body) as Record<string, unknown>
    response.setHeader("Content-Type", "application/json")
    if (request.url?.endsWith("/heartbeat")) {
      if (value.ready === false) readyFalse = true
      response.end("{}")
    } else if (request.url?.endsWith("/claim")) {
      claims++
      workers.push(String(value.workerId))
      if (mode === "lost" && claims === 1) { daemon?.kill("SIGTERM"); response.destroy(); return }
      const payload = { runId: "fixture-no-child", claimEpoch: 1, runToken: "fixture-stop-token", stopImmediately: true }
      if (mode === "delayed") {
        daemon?.kill("SIGTERM")
        setTimeout(() => response.end(JSON.stringify({ ...payload, stopImmediately: undefined, roomId: 1, generation: 1,
          providerTarget: "http://127.0.0.1:9", livekit: { serverUrl: "ws://127.0.0.1:9", token: "fixture-token" },
          model: "meeting", leaseMs: 15000, expiresAt: new Date(Date.now() + 60_000).toISOString(), participants: [] })), 300)
      } else response.end(JSON.stringify(payload))
    } else if (request.url?.endsWith("/stopped")) {
      stops++
      if (mode === "retry_stopped" && stops <= 2) { response.writeHead(503).end("{}"); return }
      setTimeout(() => {
        acknowledged = true
        response.end("{}")
        if (mode === "retry_stopped") setTimeout(() => daemon?.kill("SIGTERM"), 100)
      }, 300)
    } else response.writeHead(404).end("{}")
  })
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
  const address = server.address()
  if (!address || typeof address === "string") throw new Error("loopback fixture failed")
  try {
    daemon = fork(fileURLToPath(new URL("../dist/daemon.js", import.meta.url)), [], {
      execPath: nodeExecutable, execArgv: [], env: { GRID_TRANSCRIPTION_API_URL: `http://127.0.0.1:${address.port}`,
        GRID_TRANSCRIPTION_WORKER_SECRET: "fixture-secret", SONIOX_API_KEY: "fixture-key" },
      stdio: ["ignore", "ignore", "ignore", "ipc"],
    })
    const child = daemon
    const code = await new Promise<number | null>((resolve, reject) => {
      const timeout = setTimeout(() => { child.kill("SIGKILL"); reject(new Error("claim fixture deadline")) }, 15_000)
      child.once("error", (error) => { clearTimeout(timeout); reject(error) })
      child.once("exit", (exitCode) => { clearTimeout(timeout); prematureExit = !acknowledged; resolve(exitCode) })
    })
    return { code, claims, stops, acknowledged, prematureExit, readyFalse, sameBoot: new Set(workers).size === 1 }
  } finally {
    if (daemon && daemon.exitCode === null && daemon.signalCode === null) daemon.kill("SIGKILL")
    server.closeAllConnections()
    await new Promise<void>((resolve) => server.close(() => resolve()))
  }
}

describe("daemon configuration and real shutdown", () => {
  test("SIGTERM waits for a delayed claim response before acknowledging no child was allocated", async () => {
    expect(await noChildClaimFixture("delayed")).toEqual({ code: 0, claims: 1, stops: 1,
      acknowledged: true, prematureExit: false, readyFalse: true, sameBoot: true })
  }, 20_000)
  test("SIGTERM recovers the same boot's lost claim as stop-only authority", async () => {
    expect(await noChildClaimFixture("lost")).toEqual({ code: 0, claims: 2, stops: 1,
      acknowledged: true, prematureExit: false, readyFalse: true, sameBoot: true })
  }, 20_000)
  test("known stopped receipt retries after API recovery before another claim", async () => {
    expect(await noChildClaimFixture("retry_stopped")).toEqual({ code: 0, claims: 1, stops: 3,
      acknowledged: true, prematureExit: false, readyFalse: true, sameBoot: true })
  }, 20_000)
  test("the configured provider is internal, default meeting, and every boot has distinct authority", () => {
    const source = { GRID_TRANSCRIPTION_API_URL: "https://api.example.test", GRID_TRANSCRIPTION_WORKER_SECRET: "test-secret" }
    const first = workerConfig(source)
    const second = workerConfig(source)
    expect(first.model).toBe("meeting")
    expect(first.apiKey).toBeUndefined()
    expect(first.workerId).not.toBe(second.workerId)
    expect(first.workerId.length).toBeLessThanOrEqual(80)
    const standard = workerConfig({ ...source, GRID_TRANSCRIPTION_MODEL: "standard", OPENAI_API_KEY: "fixture-key" })
    expect(standard.model).toBe("standard")
    expect(standard.apiKey).toBe("fixture-key")
    expect(() => workerConfig({ ...source, GRID_TRANSCRIPTION_MODEL: "client-selected-model" })).toThrow("protocol")
  })

  test("compiled Node daemon SIGTERM waits for its stopped HTTP acknowledgement after actual native exit", async () => {
    // No real credentials, provider socket or remote room is contacted. The real
    // native child joins a refused loopback endpoint, exits, and reports through its watchdog.
    ensureCompiled()
    let claimed = false
    let stoppedRequested = false
    let stoppedAcknowledged = false
    let prematureExit = false
    let daemon: ReturnType<typeof fork> | undefined
    const server = createServer((request, response) => {
      response.setHeader("Content-Type", "application/json")
      if (request.url === "/_internal/grid-transcription/claim") {
        if (claimed) { response.writeHead(204).end(); return }
        claimed = true
        response.end(JSON.stringify({ runId: "fixture-run", claimEpoch: 1, roomId: 1, generation: 1,
          providerTarget: "http://127.0.0.1:9", livekit: { serverUrl: "ws://127.0.0.1:9", token: "not-a-real-token" },
          runToken: "test-run-token", model: "meeting", leaseMs: 15000,
          expiresAt: new Date(Date.now() + 60_000).toISOString(), participants: [] }))
      } else if (request.url === "/_internal/grid-transcription/stopped") {
        stoppedRequested = true
        daemon?.kill("SIGTERM")
        setTimeout(() => { stoppedAcknowledged = true; response.end("{}") }, 500)
      } else if (request.url === "/_internal/grid-transcription/renew") {
        response.end(JSON.stringify({ state: "active", allowFinalFlush: false,
          leaseExpiresAt: new Date(Date.now() + 15_000).toISOString(), participants: [] }))
      } else if (request.url === "/_internal/grid-transcription/heartbeat") response.end("{}")
      else response.writeHead(404).end("{}")
    })
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
    const address = server.address()
    if (!address || typeof address === "string") throw new Error("loopback fixture failed")
    try {
      daemon = fork(fileURLToPath(new URL("../dist/daemon.js", import.meta.url)), [], {
        execPath: nodeExecutable, execArgv: [], env: { GRID_TRANSCRIPTION_API_URL: `http://127.0.0.1:${address.port}`,
          GRID_TRANSCRIPTION_WORKER_SECRET: "test-secret", SONIOX_API_KEY: "fixture-key", NODE_ENV: "test" },
        stdio: ["ignore", "ignore", "ignore", "ipc"],
      })
      const child = daemon
      const code = await new Promise<number | null>((resolve, reject) => {
        const timeout = setTimeout(() => { child.kill("SIGKILL"); reject(new Error("daemon shutdown fixture deadline")) }, 25_000)
        child.once("error", (error) => { clearTimeout(timeout); reject(error) })
        child.once("exit", (exitCode) => {
          clearTimeout(timeout)
          prematureExit = stoppedRequested && !stoppedAcknowledged
          resolve(exitCode)
        })
      })
      expect(code).toBe(0)
      expect(stoppedRequested).toBe(true)
      expect(stoppedAcknowledged).toBe(true)
      expect(prematureExit).toBe(false)
    } finally {
      if (daemon && daemon.exitCode === null && daemon.signalCode === null) daemon.kill("SIGKILL")
      server.closeAllConnections()
      await new Promise<void>((resolve) => server.close(() => resolve()))
    }
  }, 30_000)
})
