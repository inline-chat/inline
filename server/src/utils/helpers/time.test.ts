import { describe, expect, it, beforeEach, afterEach, setSystemTime, mock } from "bun:test"
import { delay, debugDelay } from "./time"

describe("time helpers", () => {
  beforeEach(() => {
    setSystemTime(new Date())
  })

  afterEach(() => {
    setSystemTime()
  })

  describe("delay", () => {
    it("should wait for the specified time", async () => {
      const promise = delay(1000)
      setSystemTime(new Date(Date.now() + 1000))
      await promise
      // Test passes if the promise resolves
    })

    it("should not resolve before the specified time", async () => {
      const promise = delay(1000)
      setSystemTime(new Date(Date.now() + 500))

      const resolved = await Promise.race([promise.then(() => true), Promise.resolve(false)])

      expect(resolved).toBe(false)
    })
  })

  describe("debugDelay", () => {
    const originalEnv = process.env.NODE_ENV

    beforeEach(() => {
      setSystemTime(new Date())
    })

    afterEach(() => {
      setSystemTime()
    })

    it("should delay in development environment", async () => {
      process.env.NODE_ENV = "development"
      const promise = debugDelay(1000)
      setSystemTime(new Date(Date.now() + 1000))
      await promise
      // Test passes if the promise resolves
    })

    it("should not delay in production environment", async () => {
      process.env.NODE_ENV = "production"
      const start = Date.now()
      await debugDelay(1000)
      const duration = Date.now() - start
      expect(duration).toBeLessThan(50) // Should resolve almost immediately
    })
  })
})
