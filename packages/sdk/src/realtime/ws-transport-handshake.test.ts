import { createServer, type Socket } from "node:net"
import { spawnSync } from "node:child_process"
import { fileURLToPath } from "node:url"
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
    const errors: string[] = []
    const transport = new WebSocketTransport({
      url: `ws://127.0.0.1:${port}`,
      handshakeTimeoutMs: 50,
      logger: { warn: (message) => warnings.push(String(message)), error: (message) => errors.push(String(message)) },
    })

    await transport.start()
    await expect.poll(() => warnings.some((line) => line.includes("reconnect scheduled")), { timeout: 2_000 }).toBe(true)
    await transport.stop()

    expect(warnings.find((line) => line.includes("reconnect scheduled"))).toContain("handshake has timed out")
    expect(errors.some((line) => line.includes("handshake has timed out"))).toBe(true)
  })

  it("survives cancelling a connecting socket in the Bun process without reconnecting", () => {
    // A real child owns the uncaught-error boundary. An EventEmitter error can
    // otherwise pass assertions before Bun exits with a failing status.
    const modulePath = fileURLToPath(new URL("./ws-transport.ts", import.meta.url))
    const script = `
      import { createServer } from "node:net";
      import { WebSocketTransport } from ${JSON.stringify(modulePath)};
      const peers = [];
      const warnings = [];
      let accept;
      let disconnect;
      const accepted = new Promise(resolve => { accept = resolve; });
      const disconnected = new Promise(resolve => { disconnect = resolve; });
      const server = createServer(peer => {
        peers.push(peer);
        peer.on("error", () => {});
        peer.once("close", disconnect);
        // Consume the upgrade bytes without replying so EOF can close the peer.
        peer.resume();
        accept();
      });
      await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
      const transport = new WebSocketTransport({
        url: "ws://127.0.0.1:" + server.address().port,
        handshakeTimeoutMs: 5000,
        logger: { warn: message => warnings.push(message) },
      });
      try {
        await transport.start();
        await accepted;
        await transport.stop();
        // The peer's close confirms asynchronous handshake-abort I/O occurred.
        await disconnected;
        const diagnostics = transport.getDiagnostics();
        if (diagnostics.state !== "idle" || diagnostics.reconnectCount !== 0 || warnings.length !== 0 || peers.length !== 1) {
          throw new Error("Cancelled connection retained work or scheduled a reconnect");
        }
        console.log("connecting-socket-disposed");
      } finally {
        await transport.stop();
        for (const peer of peers) peer.destroy();
        await new Promise(resolve => server.close(resolve));
      }
    `
    const child = spawnSync("bun", ["--no-env-file", "--eval", script], {
      encoding: "utf8",
      timeout: 5_000,
    })
    expect(child.error).toBeUndefined()
    expect(child.status, child.stderr).toBe(0)
    expect(child.stdout.trim()).toBe("connecting-socket-disposed")
  })
})
