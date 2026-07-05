import { describe, expect, it, vi } from "vitest"
import { PingPongService } from "./ping-pong.js"

describe("PingPongService", () => {
  it("does nothing without a client", async () => {
    const svc = new PingPongService()
    await svc.ping()
    svc.pong(1n)
    svc.start()
    svc.stop()
  })

  it("sends pings, records pongs, and can trigger reconnect on timeout", async () => {
    vi.useFakeTimers()

    let sent = 0
    let reconnected = 0
    let lastNonce: bigint | null = null

    const client = {
      state: "open" as const,
      sendPing: async (nonce: bigint) => {
        sent++
        lastNonce = nonce
      },
      reconnect: async () => {
        reconnected++
      },
    }

    const svc = new PingPongService({ crypto: null })
    svc.configure(client as any)

    svc.start()

    // First loop iteration sleeps 10s then pings.
    await vi.advanceTimersByTimeAsync(10_000)
    expect(sent).toBe(1)
    expect(lastNonce).not.toBeNull()
    svc.pong(lastNonce!)

    // Pong with unknown nonce should be ignored.
    svc.pong(999n)

    // Advance enough so a later loop check sees a ping as timed out and reconnects.
    await vi.advanceTimersByTimeAsync(60_000)
    expect(reconnected).toBeGreaterThanOrEqual(1)

    svc.stop()
    vi.useRealTimers()
  })

  it("uses crypto.getRandomValues() when provided", async () => {
    vi.useFakeTimers()

    const crypto = {
      getRandomValues: (buf: Uint32Array) => {
        buf[0] = 1
        buf[1] = 2
        return buf
      },
    } as unknown as Crypto

    let seenNonce: bigint | null = null
    const client = {
      state: "open" as const,
      sendPing: async (nonce: bigint) => {
        seenNonce = nonce
      },
      reconnect: async () => {},
    }

    const svc = new PingPongService({ crypto })
    svc.configure(client as any)

    await svc.ping()

    expect(seenNonce).toBe((1n << 32n) | 2n)
    vi.useRealTimers()
  })

  it("falls back to globalThis.crypto when options.crypto is omitted", async () => {
    vi.useFakeTimers()

    try {
      vi.stubGlobal("crypto", {
        getRandomValues: (buf: Uint32Array) => {
          buf[0] = 7
          buf[1] = 9
          return buf
        },
      })

      let seenNonce: bigint | null = null
      const client = {
        state: "open" as const,
        sendPing: async (nonce: bigint) => {
          seenNonce = nonce
        },
        reconnect: async () => {},
      }

      const svc = new PingPongService()
      svc.configure(client as any)
      await svc.ping()

      expect(seenNonce).toBe((7n << 32n) | 9n)
    } finally {
      vi.unstubAllGlobals()
      vi.useRealTimers()
    }
  })

  it("covers checkConnection() early return when client is not open and sleep(0) fast-path", async () => {
    const svc = new PingPongService({ crypto: null })
    svc.configure({
      state: "connecting",
      sendPing: async (_nonce: bigint) => {},
      reconnect: async () => {},
    } as any)

    await expect((svc as any).checkConnection()).resolves.toBeUndefined()
    await expect((svc as any).sleep(0)).resolves.toBeUndefined()
  })

  it("covers constructor branch when globalThis.crypto is not usable + start() idempotency", async () => {
    vi.useFakeTimers()
    const randomSpy = vi.spyOn(Math, "random").mockReturnValue(0)
    try {
      vi.stubGlobal("crypto", { getRandomValues: 123 })

      let seenNonce: bigint | null = null
      const client = {
        state: "open" as const,
        sendPing: async (nonce: bigint) => {
          seenNonce = nonce
        },
        reconnect: async () => {},
      }

      const svc = new PingPongService()
      svc.configure(client as any)

      // start() while already running should no-op.
      svc.start()
      svc.start()
      svc.stop()

      await svc.ping()
      expect(seenNonce).toBe(0n)
    } finally {
      randomSpy.mockRestore()
      vi.unstubAllGlobals()
      vi.useRealTimers()
    }
  })

  it("does not ping when client is not open", async () => {
    const svc = new PingPongService({ crypto: null })
    let sent = 0
    svc.configure({
      state: "connecting",
      sendPing: async (_nonce: bigint) => {
        sent++
      },
      reconnect: async () => {},
    } as any)

    await svc.ping()
    expect(sent).toBe(0)
  })
})
