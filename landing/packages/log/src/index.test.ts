import { describe, expect, it, vi } from "vitest"
import {
  Log,
  LogRingBuffer,
  sanitizeLogFields,
  type LogSink,
} from "./index"

const silentSink = (): LogSink => ({
  error: vi.fn(),
  warn: vi.fn(),
  info: vi.fn(),
  debug: vi.fn(),
  trace: vi.fn(),
})

describe("Log", () => {
  it("shares runtime levels and structured sinks with child scopes", () => {
    const buffer = new LogRingBuffer(4)
    const root = new Log("Web", {
      level: "info",
      sink: false,
      recordSinks: [buffer],
      now: () => 123,
    })
    const sync = root.withScope("Sync").withFields({ runId: "run-1" })

    sync.debug("sync.ignored")
    sync.info("sync.ready", { generation: 2 })
    root.setLevel("debug")
    sync.debug("sync.bucket.committed", { seq: 42n })

    expect(buffer.snapshot()).toEqual([
      {
        timestamp: 123,
        sequence: 0,
        level: "info",
        scope: "Web.Sync",
        event: "sync.ready",
        fields: { runId: "run-1", generation: 2 },
      },
      {
        timestamp: 123,
        sequence: 1,
        level: "debug",
        scope: "Web.Sync",
        event: "sync.bucket.committed",
        fields: { runId: "run-1", seq: "42n" },
      },
    ])
  })

  it("bounds the live ring buffer", () => {
    const buffer = new LogRingBuffer(2)
    const log = new Log("Web", { sink: false, recordSinks: [buffer] })

    log.info("one")
    log.info("two")
    log.info("three")

    expect(buffer.snapshot().map((record) => record.event)).toEqual(["two", "three"])
    buffer.clear()
    expect(buffer.snapshot()).toEqual([])
  })

  it("bounds the live ring by bytes and reports evictions", () => {
    const buffer = new LogRingBuffer(10, 240)
    const log = new Log("Web", { sink: false, recordSinks: [buffer] })

    log.info("one", { detail: "a".repeat(80) })
    log.info("two", { detail: "b".repeat(80) })
    log.info("three", { detail: "c".repeat(80) })

    expect(buffer.sizeBytes).toBeLessThanOrEqual(240)
    expect(buffer.droppedCount).toBeGreaterThan(0)
  })

  it("redacts private fields and safely normalizes hostile values", () => {
    const circular: Record<string, unknown> = {}
    circular.self = circular
    const fields = sanitizeLogFields({
      token: "secret-token",
      apiToken: "another-secret-token",
      messageText: "private chat text",
      content: "private content",
      caption: "private caption",
      displayName: "Private Person",
      userId: 123n,
      chatId: 456n,
      messageId: 789n,
      interactionId: 999n,
      apiKey: "private-api-key",
      runId: "run-safe-correlation",
      email: "person@example.com",
      seq: 55n,
      circular,
      bytes: new Uint8Array(4),
      error: new Error("request to http://localhost:8001/chat/user/123?token=private failed", {
        cause: new Error("Bearer private-token at /Users/example/private/file.ts"),
      }),
    })

    expect(fields).toMatchObject({
      token: "[redacted]",
      apiToken: "[redacted]",
      messageText: "[redacted]",
      content: "[redacted]",
      caption: "[redacted]",
      displayName: "[redacted]",
      userId: "[redacted]",
      chatId: "[redacted]",
      messageId: "[redacted]",
      interactionId: "[redacted]",
      apiKey: "[redacted]",
      runId: "run-safe-correlation",
      email: "[redacted]",
      seq: "55n",
      circular: { self: "[circular]" },
      bytes: "[Uint8Array 4 bytes]",
      error: {
        name: "Error",
        message: "request to [redacted-url] failed",
        cause: {
          name: "Error",
          message: "Bearer [redacted] at [redacted-path]",
        },
      },
    })
  })

  it("redacts browser, websocket, query, and platform-local paths", () => {
    const fields = sanitizeLogFields({
      browser: "http://127.0.0.1:8001/chat/user/123?messageId=456",
      socket: "wss://api.inline.chat/realtime?token=private",
      windows: "C:\\Users\\example\\private\\source.ts",
      query: "request failed?access_token=private&retry=true",
      blob: "blob:http://localhost:8001/private-object",
      data: "data:text/html,<private>",
      workspace: "at /workspace/web/src/app.ts:42:1",
    })

    expect(fields).toEqual({
      browser: "[redacted-url]",
      socket: "[redacted-url]",
      windows: "[redacted-path]",
      query: "request failed?access_token=[redacted]&retry=true",
      blob: "[redacted-url]",
      data: "[redacted-url]",
      workspace: "at [redacted-path]:42:1",
    })
  })

  it("stores an immutable JSON-safe snapshot", () => {
    const buffer = new LogRingBuffer()
    const mutable = { nested: { state: "before" }, seq: 7n }
    const log = new Log("Web", { sink: false, recordSinks: [buffer] })

    log.info("runtime.snapshot", mutable)
    mutable.nested.state = "after"

    const [record] = buffer.snapshot()
    expect(record?.fields).toEqual({ nested: { state: "before" }, seq: "7n" })
    expect(Object.isFrozen(record?.fields?.nested)).toBe(true)
    expect(() => JSON.stringify(record)).not.toThrow()
  })

  it("does not let a sink failure escape", () => {
    const log = new Log("Web", {
      sink: false,
      recordSinks: [{ write: () => { throw new Error("sink failed") } }],
    })

    expect(() => log.error("runtime.failed", new Error("boom"))).not.toThrow()
  })

  it("does not let hostile structured fields escape", () => {
    const fields = new Proxy({}, {
      ownKeys: () => { throw new Error("getter failed") },
    })
    const log = new Log("Web", { sink: false })

    expect(() => log.info("runtime.failed", fields)).not.toThrow()
    expect(sanitizeLogFields(fields)).toEqual({ serialization: "[unserializable]" })
  })

  it("preserves the legacy console sink API", () => {
    const sink = silentSink()
    const log = new Log("Realtime", "trace", sink)

    log.warn("connection.degraded", new Error("offline"))

    expect(sink.warn).toHaveBeenCalledWith(
      "[Realtime] connection.degraded",
      {
        details: [{ name: "Error", message: "offline", stack: expect.any(String) }],
      },
    )
  })
})
