import { afterEach, describe, expect, it } from "bun:test"
import { RedisClient } from "bun"
import { createServer } from "node:net"
import { InternalRedisTransport } from "./redis"

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

  it("starts without a broker and returns explicit unavailable operations", async () => {
    for (const url of [undefined, " \t "]) {
      const transport = new InternalRedisTransport(url)
      await transport.start(["optional-broker"], () => {})
      expect(transport.health).toBe("unavailable")
      expect(await transport.publish("optional-broker", "hint")).toEqual({ status: "unavailable" })
      expect(await transport.setExpiring("activity", "1", 1_000)).toBe(false)
      expect(await transport.get("activity")).toBeUndefined()
      await transport.close()
      expect(transport.health).toBe("closed")
    }
  })

  it("finishes startup when a configured broker is unavailable", async () => {
    const listener = createServer()
    await new Promise<void>((resolve) => listener.listen(0, "127.0.0.1", resolve))
    const address = listener.address()
    if (!address || typeof address === "string") throw new Error("Missing loopback port")
    await new Promise<void>((resolve) => listener.close(() => resolve()))

    const transport = new InternalRedisTransport(`redis://127.0.0.1:${address.port}`)
    try {
      await transport.start(["temporarily-unavailable"], () => {})
      expect(transport.health).toBe("unavailable")
      expect(await transport.publish("temporarily-unavailable", "hint")).toEqual({ status: "unavailable" })
    } finally {
      await transport.close()
    }
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
      // Socket counts alone miss Bun's local subscription references: the
      // entire child must exit naturally after normal and recovered shutdown.
      await expectTransportProcessExit(url, control)
      await expectTransportProcessExit(url, control, side)
      await waitUntil(async () => (await clients()).length === 1)
    }, 25_000)
  }
})

async function expectTransportProcessExit(
  url: string,
  control: RedisClient,
  disconnect?: "commands" | "subscriber",
): Promise<void> {
  const code = `
    import { InternalRedisTransport } from ${JSON.stringify(import.meta.dir + "/redis.ts")};
    const transport = new InternalRedisTransport(${JSON.stringify(url)});
    const recovered = Promise.withResolvers();
    let readyCount = 0;
    transport.onReady(() => { if (++readyCount === 2) recovered.resolve(); });
    await transport.start(["process-exit-a", "process-exit-b"], () => {});
    if (transport.health !== "ready") throw new Error("Child broker not ready");
    console.log("READY");
    ${disconnect ? "await recovered.promise;" : ""}
    await transport.close();
  `
  const child = Bun.spawn({
    cmd: [process.execPath, "--no-env-file", "--eval", code],
    stdin: "ignore", stdout: "pipe", stderr: "pipe",
  })
  const timer = setTimeout(() => child.kill("SIGTERM"), 4_000)
  const reader = child.stdout.getReader()
  try {
    const ready = await reader.read()
    expect(new TextDecoder().decode(ready.value)).toContain("READY")
    if (disconnect) {
      const controlId = String(await control.send("CLIENT", ["ID"]))
      const clients = String(await control.send("CLIENT", ["LIST"]))
        .trim().split("\n").map((line) => Object.fromEntries(line.split(" ").map((part) => part.split("="))))
      const pair = clients.filter((client) => client.id !== controlId)
      expect(pair).toHaveLength(2)
      const victim = pair.find((client) => (client.sub !== "0") === (disconnect === "subscriber"))
      if (!victim?.id) throw new Error("Missing child Redis connection to kill")
      await control.send("CLIENT", ["KILL", "ID", victim.id])
    }
    expect(await child.exited).toBe(0)
    expect(await new Response(child.stderr).text()).toBe("")
  } finally {
    clearTimeout(timer)
    reader.releaseLock()
    if (child.exitCode === null) child.kill("SIGTERM")
    await child.exited
  }
}
