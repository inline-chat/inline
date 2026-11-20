import { describe, expect, it } from "bun:test"
import type { ErrorEvent } from "@sentry/bun"
import { ErrorBurstDetector, errorBurstKey, formatErrorBurstAlert } from "./errorBurstAlerts"

const options = { windowMs: 10 * 60_000, threshold: 5, cooldownMs: 2 * 60 * 60_000, maxKeys: 3 }

describe("ErrorBurstDetector", () => {
  it("pages once when one error repeats within the window, then waits for the cooldown", () => {
    const detector = new ErrorBurstDetector(options)
    const results = Array.from({ length: 8 }, (_, i) => detector.record("A", i * 1_000))
    expect(results.slice(0, 4)).toEqual([null, null, null, null])
    expect(results[4]).toEqual({ count: 5, repeat: false, totalSinceAlert: 5 })
    expect(results.slice(5)).toEqual([null, null, null])
  })

  it("does not page for errors spread thinner than the threshold", () => {
    const detector = new ErrorBurstDetector(options)
    for (let i = 0; i < 20; i++) {
      expect(detector.record("A", i * 3 * 60_000)).toBeNull()
    }
  })

  it("pages again after the cooldown while the error keeps happening", () => {
    const detector = new ErrorBurstDetector(options)
    for (let i = 0; i < 5; i++) detector.record("A", i)
    let second: ReturnType<ErrorBurstDetector["record"]> = null
    for (let t = 60_000; t <= 3 * 60 * 60_000 && !second; t += 60_000) {
      second = detector.record("A", t)
    }
    expect(second).toMatchObject({ repeat: true })
    expect(second?.totalSinceAlert).toBeGreaterThan(5)
  })

  it("keeps errors apart by key and bounds the keys it tracks", () => {
    const detector = new ErrorBurstDetector(options)
    for (let i = 0; i < 4; i++) detector.record("A", i)
    for (const key of ["B", "C", "D"]) detector.record(key, 10)
    // A was evicted, so its count starts over.
    expect(detector.record("A", 20)).toBeNull()
  })
})

describe("errorBurstKey", () => {
  it("uses the innermost exception type and the request path without the query", () => {
    const event = {
      type: undefined,
      exception: { values: [{ type: "Wrapper" }, { type: "OAuthResponseContractFailure" }] },
      request: { method: "POST", url: "https://api.inline.chat/oauth/introspect?token=secret" },
    } as ErrorEvent
    expect(errorBurstKey(event)).toEqual({
      key: "OAuthResponseContractFailure | POST /oauth/introspect",
      errorType: "OAuthResponseContractFailure",
      route: "POST /oauth/introspect",
    })
  })

  it("falls back to the transaction when there is no request", () => {
    expect(errorBurstKey({ type: undefined, transaction: "worker.sync" } as ErrorEvent).route).toBe("worker.sync")
  })
})

describe("formatErrorBurstAlert", () => {
  it("names the error, route, rate and a Sentry search", () => {
    const text = formatErrorBurstAlert({
      errorType: "OAuthResponseContractFailure",
      route: "POST /oauth/introspect",
      count: 5,
      windowMs: 10 * 60_000,
      repeat: false,
      totalSinceAlert: 5,
      release: "39a6c42f6",
      machine: "874416da053038",
    })
    expect(text).toContain("OAuthResponseContractFailure on POST /oauth/introspect")
    expect(text).toContain("5 in the last 10 min.")
    expect(text).toContain("machine 874416da053038 · release 39a6c42f6")
    expect(text).toContain("error.type%3AOAuthResponseContractFailure")
  })
})
