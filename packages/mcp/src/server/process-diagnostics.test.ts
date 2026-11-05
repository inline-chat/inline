import { spawnSync } from "node:child_process"
import { fileURLToPath } from "node:url"
import { describe, expect, it } from "vitest"
import { classifyProcessFailure, installMcpProcessDiagnostics, mcpProcessIdentity } from "./process-diagnostics"

const SHA = "1234567890abcdef1234567890abcdef12345678"
const CANARY = "private-token-and-request-content"

describe("MCP process diagnostics", () => {
  it("validates source identity and falls back to the runtime source commit", () => {
    expect(mcpProcessIdentity({ INLINE_MCP_REVISION: CANARY, SOURCE_COMMIT: SHA }).revision).toBe(SHA)
    expect(mcpProcessIdentity({ INLINE_MCP_REVISION: SHA, SOURCE_COMMIT: "f".repeat(40) }).revision).toBe(SHA)
    expect(mcpProcessIdentity({ SOURCE_COMMIT: CANARY }).revision).toBeNull()
  })

  it("retains only closed error metadata and known module coordinates", () => {
    const error = Object.assign(new TypeError(CANARY), { code: CANARY, headers: { authorization: CANARY } })
    error.stack = `TypeError: ${CANARY}\n at /private/${CANARY}.ts:1:2\n at /app/packages/sdk/dist/realtime/ws-transport.js:103:4`
    expect(classifyProcessFailure(error)).toEqual({ errorName: "TypeError", module: "sdk/ws-transport", line: 103, column: 4 })
    expect(JSON.stringify(classifyProcessFailure(error))).not.toContain(CANARY)
    expect(classifyProcessFailure(Object.assign(new Error(CANARY), { code: "ECONNRESET" }))).toEqual({ errorName: "Error", errorCode: "ECONNRESET" })
    expect(classifyProcessFailure(CANARY)).toEqual({ errorName: "NonError" })
    error.stack = `TypeError: ${CANARY}\n at emitErrorAndClose (ws:875:74)`
    expect(classifyProcessFailure(error)).toEqual({ errorName: "TypeError", module: "ws", line: 875, column: 74 })
  })

  it("does not make diagnostic write failures fatal", () => {
    const diagnostics = installMcpProcessDiagnostics({ write: () => { throw new Error(CANARY) } })
    try {
      expect(() => diagnostics.started()).not.toThrow()
      expect(() => diagnostics.startupFailure(new Error(CANARY))).not.toThrow()
    } finally { diagnostics.dispose() }
  })

  it("preserves Bun's fatal rejection behavior without installing a rejection handler", () => {
    const modulePath = fileURLToPath(new URL("./process-diagnostics.ts", import.meta.url))
    const child = spawnSync("bun", ["--no-env-file", "--eval", `
      import { installMcpProcessDiagnostics } from ${JSON.stringify(modulePath)};
      installMcpProcessDiagnostics().started();
      console.log(process.listenerCount("unhandledRejection"));
      Promise.reject(new Error(${JSON.stringify(CANARY)}));
    `], { encoding: "utf8", timeout: 5_000 })
    expect(child.error).toBeUndefined()
    expect(child.status).toBe(1)
    expect(child.stdout.trim()).toBe("0")
  })

  for (const trigger of [
    `setTimeout(() => { throw Object.assign(new TypeError(${JSON.stringify(CANARY)}), { code: "ECONNRESET" }) }, 0)`,
    `const { EventEmitter } = await import("node:events"); setTimeout(() => new EventEmitter().emit("error", new Error(${JSON.stringify(CANARY)})), 0)`,
  ]) {
    it("observes a real Bun fatal error without changing its exit status or retaining content", () => {
      const modulePath = fileURLToPath(new URL("./process-diagnostics.ts", import.meta.url))
      const child = spawnSync("bun", ["--no-env-file", "--eval", `
        import { installMcpProcessDiagnostics } from ${JSON.stringify(modulePath)};
        installMcpProcessDiagnostics().started();
        ${trigger};
      `], { encoding: "utf8", timeout: 5_000, env: { ...process.env, INLINE_MCP_REVISION: SHA } })
      expect(child.error).toBeUndefined()
      expect(child.status).toBe(1)
      // Bun retains its own default stack reporting. New structured records
      // must not duplicate private error messages, request data or raw frames.
      const records = child.stderr.split("\n").filter((line) => line.startsWith('{"event":"mcp.process.')).map((line) => JSON.parse(line))
      expect(records.map((record) => record.event)).toEqual(["mcp.process.started", "mcp.process.fatal", "mcp.process.exit"])
      expect(records.every((record) => record.revision === SHA && /^bun-\d+\.\d+\.\d+/.test(record.runtime))).toBe(true)
      expect(records[1].category).toBe("uncaught_exception")
      expect(records[2].exitCode).toBe(1)
      expect(JSON.stringify(records)).not.toContain(CANARY)
    })
  }
})
