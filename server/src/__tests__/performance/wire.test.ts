import { expect, test } from "bun:test"
import { connect, createServer, type Socket } from "node:net"
import { createWireProxy } from "./wire"

function requestBytes() {
  const startup = Buffer.alloc(8)
  startup.writeUInt32BE(8)
  startup.writeUInt32BE(196608, 4)
  const query = Buffer.alloc(5 + 96 * 1024)
  query[0] = "Q".charCodeAt(0)
  query.writeUInt32BE(query.length - 1, 1)
  query.fill(97, 5)
  return { startup, query }
}

test.each(["client", "server"] as const)("delayed proxy preserves queued bytes when %s half-closes first", async (first) => {
  const { startup, query } = requestBytes()
  const request = Buffer.concat([startup, query])
  const response = Buffer.alloc(256 * 1024, 87)
  const received = Promise.withResolvers<Buffer>()
  const peers = new Set<Socket>()
  const server = createServer({ allowHalfOpen: true }, (peer) => {
    peers.add(peer)
    const chunks: Buffer[] = []
    let replied = false
    peer.on("data", (chunk: Buffer) => {
      chunks.push(chunk)
      if (first === "server" && !replied) { replied = true; peer.end(response) }
    })
    peer.on("end", () => {
      received.resolve(Buffer.concat(chunks))
      if (first === "client") peer.end(response)
    })
    peer.on("error", received.reject)
    peer.on("close", () => peers.delete(peer))
  })
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject)
    server.listen(0, "127.0.0.1", () => { server.off("error", reject); resolve() })
  })
  const address = server.address()
  if (!address || typeof address === "string") throw new Error("Missing fixture port")
  const proxy = await createWireProxy({ host: "127.0.0.1", port: address.port }, 50)
  const client = connect({ host: "127.0.0.1", port: proxy.port, allowHalfOpen: true })
  const reply = new Promise<Buffer>((resolve, reject) => {
    const chunks: Buffer[] = []
    client.on("data", (chunk: Buffer) => chunks.push(chunk))
    client.on("error", reject)
    client.on("end", () => {
      // Even after receiving the server's EOF, the request direction remains
      // writable until the client explicitly finishes its remaining bytes.
      if (first === "server") client.end(query)
      resolve(Buffer.concat(chunks))
    })
    client.on("close", () => {
      if (!client.readableEnded) reject(new Error("Proxy closed before response EOF"))
    })
  })
  try {
    if (first === "client") client.end(request)
    else client.write(startup)
    const [actualRequest, actualResponse] = await Promise.all([received.promise, reply])
    expect(actualRequest.equals(request)).toBe(true)
    expect(actualResponse.equals(response)).toBe(true)
    expect(proxy.snapshot()).toMatchObject({ clientBytes: request.length, serverBytes: response.length, frames: { Q: 1 } })
  } finally {
    client.destroy()
    await proxy.close()
    for (const peer of peers) peer.destroy()
    await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()))
  }
})
