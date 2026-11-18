import { afterEach, describe, expect, it, vi } from "vitest"
import { PingPongService } from "./ping-pong"
import type { ProtocolClient } from "./protocol-client"

describe("PingPongService", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("matches a pong that arrives before the ping's send settles", async () => {
    vi.useFakeTimers()
    const service = new PingPongService()
    const onTimeout = vi.fn()
    // An in-process server answers inside the send, before it resolves.
    const client = {
      state: "open",
      sendPing: async (nonce: bigint) => {
        service.pong(nonce)
      },
    } as unknown as ProtocolClient
    service.configure(client, onTimeout)
    service.start()

    // Pings every 10 s; an unmatched one would read as timed out after 30 s.
    await vi.advanceTimersByTimeAsync(60_000)
    service.stop()

    expect(onTimeout).not.toHaveBeenCalled()
  })
})
