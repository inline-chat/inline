import { connect, createServer, type Socket } from "node:net"
import type { WireCounts } from "./measure"

/** Streaming frontend framing only. Never retain or decode SQL/bind payloads. */
export class FrontendFrames {
  private header = Buffer.alloc(5)
  private headerSize = 0
  private remaining = 0
  private startup = true

  constructor(private readonly onFrame: (kind: string) => void) {}

  accept(chunk: Buffer): void {
    let offset = 0
    while (offset < chunk.length) {
      if (this.remaining) {
        const consumed = Math.min(this.remaining, chunk.length - offset)
        offset += consumed
        this.remaining -= consumed
        continue
      }
      const needed = this.startup ? 4 : 5
      const consumed = Math.min(needed - this.headerSize, chunk.length - offset)
      chunk.copy(this.header, this.headerSize, offset, offset + consumed)
      this.headerSize += consumed
      offset += consumed
      if (this.headerSize !== needed) continue
      const length = this.header.readUInt32BE(this.startup ? 0 : 1)
      if (length < (this.startup ? 8 : 4) || length > 64 * 1024 * 1024) {
        throw new Error("Invalid or oversized PostgreSQL frontend frame")
      }
      this.remaining = length - 4
      if (!this.startup) this.onFrame(String.fromCharCode(this.header[0]!))
      this.startup = false
      this.headerSize = 0
    }
  }
}

/** Plaintext, loopback-only test proxy. Half the requested delay per direction;
 * this is controlled transport delay, not a PlanetScale or WAN simulator. */
export async function createWireProxy(target: { host: string; port: number }, rttMs: number) {
  if (!["localhost", "127.0.0.1"].includes(target.host) || !Number.isInteger(target.port) ||
      target.port < 1 || target.port > 65535 || !Number.isFinite(rttMs) || rttMs < 0 || rttMs > 50) {
    throw new Error("The benchmark proxy requires a loopback PostgreSQL port and RTT between 0 and 50 ms")
  }
  const sockets = new Set<Socket>()
  const timers = new Set<ReturnType<typeof setTimeout>>()
  const failures: Error[] = []
  let delayMs = rttMs
  let counts: WireCounts
  const reset = () => { counts = { frames: {}, exchangeBoundaries: 0, clientBytes: 0, serverBytes: 0 } }
  reset()
  const server = createServer({ allowHalfOpen: true }, (client) => {
    const upstream = connect({ host: target.host, port: target.port, allowHalfOpen: true })
    for (const socket of [client, upstream]) { sockets.add(socket); socket.setNoDelay(true) }
    const frames = new FrontendFrames((kind) => {
      counts.frames[kind] = (counts.frames[kind] ?? 0) + 1
      if (kind === "Q" || kind === "H" || kind === "S") counts.exchangeBoundaries++
    })
    const forward = (source: Socket, destination: Socket, observe: (bytes: Buffer) => void) => {
      let pending = 0
      let ended = false
      const finish = () => {
        // Reading EOF must not end the destination before its delayed writes.
        if (ended && !pending && !destination.destroyed) destination.end()
      }
      source.on("data", (bytes: Buffer) => {
        try { observe(bytes) } catch (error) { failures.push(error as Error); source.destroy(); return }
        source.pause()
        pending++
        const write = () => {
          if (destination.destroyed) { pending--; return }
          destination.write(bytes, () => {
            pending--
            finish()
            if (!source.destroyed) source.resume()
          })
        }
        if (!delayMs) write()
        else {
          const timer = setTimeout(() => { timers.delete(timer); write() }, delayMs / 2)
          timers.add(timer)
        }
      })
      source.on("end", () => { ended = true; finish() })
    }
    forward(client, upstream, (bytes) => { frames.accept(bytes); counts.clientBytes += bytes.length })
    forward(upstream, client, (bytes) => { counts.serverBytes += bytes.length })
    client.on("error", (error) => { failures.push(error); upstream.destroy() })
    upstream.on("error", (error) => { failures.push(error); client.destroy() })
    for (const [socket, peer] of [[client, upstream], [upstream, client]] as const) {
      socket.on("close", () => {
        sockets.delete(socket)
        // A cleanly closed source can still have delayed bytes headed to its
        // peer. Abort the pair only for an incomplete/failed connection.
        if (!socket.readableEnded || !socket.writableFinished) peer.destroy()
      })
    }
  })
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject)
    server.listen(0, "127.0.0.1", () => { server.off("error", reject); resolve() })
  })
  const address = server.address()
  if (!address || typeof address === "string") throw new Error("Missing benchmark proxy port")
  return {
    port: address.port,
    reset,
    setDelay(ms: number) {
      if (!Number.isFinite(ms) || ms < 0 || ms > 50) throw new Error("RTT must be between 0 and 50 ms")
      if (timers.size) throw new Error("Drain database work before changing transport delay")
      delayMs = ms
    },
    snapshot(): WireCounts {
      if (failures.length) throw new AggregateError(failures, "Benchmark transport failed")
      return { ...counts, frames: { ...counts.frames } }
    },
    async close() {
      for (const timer of timers) clearTimeout(timer)
      for (const socket of sockets) socket.destroy()
      await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()))
    },
  }
}
