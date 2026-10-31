import { createServer, type Socket } from "node:net"
import { afterEach, describe, expect, it } from "vitest"
import { WebSocketTransport } from "./ws-transport"

describe("WebSocketTransport handshake", () => {
  const sockets: Socket[] = []
  const server = createServer((socket) => {
    sockets.push(socket)
    socket.on("error", () => {})
  })

  afterEach(() => {
    for (const socket of sockets.splice(0)) socket.destroy()
    server.close()
  })

  it("retries when the network accepts the connection and never answers", async () => {
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
    const { port } = server.address() as { port: number }
    const warnings: string[] = []
    const transport = new WebSocketTransport({
      url: `ws://127.0.0.1:${port}`,
      handshakeTimeoutMs: 50,
      logger: { warn: (message) => warnings.push(String(message)), error: () => {} },
    })

    await transport.start()
    await expect.poll(() => warnings.some((line) => line.includes("reconnect scheduled")), { timeout: 2_000 }).toBe(true)
    await transport.stop()

    expect(warnings.find((line) => line.includes("reconnect scheduled"))).toContain("handshake has timed out")
  })
})
