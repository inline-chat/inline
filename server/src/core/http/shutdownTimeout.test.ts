import { describe, expect, test } from "bun:test"
import {
  DEFAULT_CORE_GRACEFUL_SHUTDOWN_MILLIS,
  parseCoreGracefulShutdownMillis,
} from "./shutdownTimeout"

describe("core graceful shutdown deadline", () => {
  test("maps the reviewed Fly deadline to the host value", () => {
    expect(parseCoreGracefulShutdownMillis(undefined)).toBe(
      DEFAULT_CORE_GRACEFUL_SHUTDOWN_MILLIS,
    )
    expect(parseCoreGracefulShutdownMillis(" 40000 ")).toBe(40_000)
  })

  test("rejects malformed or unsafe deadlines instead of silently changing drain behavior", () => {
    for (const value of ["", "   ", "0", "999", "120001", "40000.5", "40s", "not-a-number"]) {
      expect(() => parseCoreGracefulShutdownMillis(value)).toThrow(
        "SHUTDOWN_TIMEOUT_MS",
      )
    }
  })
})
