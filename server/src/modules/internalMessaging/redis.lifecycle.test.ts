import { afterEach, describe, expect, it } from "bun:test"
import { RedisClient } from "bun"
import { createServer } from "node:net"
import { InternalBrokerConfigurationError, InternalRedisTransport } from "./redis"

const redisExecutable = Bun.which("redis-server")
const waitUntil = async (condition: () => boolean | Promise<boolean>, timeoutMs = 6_000): Promise<void> => {
  const deadline = Date.now() + timeoutMs
  while (!(await condition())) {
    if (Date.now() >= deadline) throw new Error("Timed out waiting for Redis pair recovery")
    await Bun.sleep(20)
  }
}

describe("Redis connection pair lifecycle", () => {
  const cleanups: (() => Promise<unknown>)[] = []
  afterEach(async () => {
    for (const cleanup of cleanups.reverse()) await cleanup()
    cleanups.length = 0
  })

  it("rejects missing or blank broker configuration before startup", async () => {
    for (const url of [undefined, " \t "]) {
      const transport = new InternalRedisTransport(url)
      await expect(transport.start(["required-broker"], () => {})).rejects.toBeInstanceOf(
        InternalBrokerConfigurationError,
      )
      expect(transport.health).toBe("unavailable")
      await transport.close()
    }
  })

  it("keeps waiting when a configured broker is temporarily unavailable", async () => {
    const listener = createServer()
    await new Promise<void>((resolve) => listener.listen(0, "127.0.0.1", resolve))
    const address = listener.address()
    if (!address || typeof address === "string") throw new Error("Missing loopback port")
    await new Promise<void>((resolve) => listener.close(() => resolve()))

    const transport = new InternalRedisTransport(`redis://127.0.0.1:${address.port}`)
    let settled = false
    const start = transport.start(["temporarily-unavailable"], () => {}).finally(() => {
      settled = true
    })

    await Bun.sleep(20)
    expect(transport.health).toBe("unavailable")
    expect(settled).toBe(false)

    await transport.close()
    await expect(start).rejects.toThrow(
      "Broker transport closed before becoming ready",
    )
  })

  for (const side of ["commands", "subscriber"] as const) {
    it.skipIf(!redisExecutable)(`closes the surviving peer after a ${side} disconnect`, async () => {
      const listener = createServer()
      await new Promise<void>((resolve) => listener.listen(0, "127.0.0.1", resolve))
      const address = listener.address()
      if (!address || typeof address === "string") throw new Error("Missing loopback port")
      await new Promise<void>((resolve) => listener.close(() => resolve()))
      const redis = Bun.spawn({
        cmd: [redisExecutable!, "--bind", "127.0.0.1", "--port", String(address.port), "--save", "", "--appendonly", "no"],
        stdout: "ignore", stderr: "ignore",
      })
      cleanups.push(async () => { redis.kill("SIGTERM"); await redis.exited })
      const url = `redis://127.0.0.1:${address.port}`
      const control = new RedisClient(url)
      cleanups.push(async () => { control.close() })
      await control.connect()
      const transport = new InternalRedisTransport(url)
      cleanups.push(() => transport.close())
      let readyCount = 0
      let lostCount = 0
      const received: string[] = []
      transport.onReady(() => { readyCount++ })
      transport.onContinuityLost(() => { lostCount++ })
      await transport.start(["pair-regression"], (message) => { received.push(message) })
      await waitUntil(() => transport.health === "ready")
      const controlId = String(await control.send("CLIENT", ["ID"]))
      const clients = async () => String(await control.send("CLIENT", ["LIST"]))
        .trim().split("\n").map((line) => Object.fromEntries(line.split(" ").map((part) => part.split("="))))

      for (let attempt = 0; attempt < 3; attempt++) {
        const pair = (await clients()).filter((client) => client.id !== controlId)
        expect(pair).toHaveLength(2)
        const victim = pair.find((client) => (client.sub !== "0") === (side === "subscriber"))
        if (!victim?.id) throw new Error("Missing connection to kill")
        const priorReadyCount = readyCount
        await control.send("CLIENT", ["KILL", "ID", victim.id])
        await waitUntil(() => readyCount > priorReadyCount)
        // Redis must see only this pair plus our observer, even after repeated loss.
        expect(await clients()).toHaveLength(3)
        expect(await control.send("PUBSUB", ["NUMSUB", "pair-regression"])).toEqual(["pair-regression", 1])
        expect(lostCount).toBe(attempt + 1)
        const message = `after-recovery-${attempt}`
        await control.publish("pair-regression", message)
        await waitUntil(() => received.includes(message))
        expect(received.filter((value) => value === message)).toHaveLength(1)
      }
      await transport.close()
      await waitUntil(async () => (await clients()).length === 1)
    }, 25_000)
  }
})
