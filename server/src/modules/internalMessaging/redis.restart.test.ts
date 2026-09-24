import { afterEach, describe, expect, it } from "bun:test"
import { createServer } from "node:net"
import { ConnectionDirectory } from "./directory"
import { InternalMessagingService } from "./service"

const redisExecutable = Bun.which("redis-server")

const waitUntil = async (condition: () => boolean | Promise<boolean>, timeoutMs = 6_000): Promise<void> => {
  const deadline = Date.now() + timeoutMs
  while (!(await condition())) {
    if (Date.now() >= deadline) throw new Error("Timed out waiting for isolated Redis state")
    await Bun.sleep(25)
  }
}

const unusedLoopbackPort = async (): Promise<number> => {
  const server = createServer()
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject)
    server.listen(0, "127.0.0.1", resolve)
  })
  const address = server.address()
  if (!address || typeof address === "string") throw new Error("No loopback port")
  await new Promise<void>((resolve) => server.close(() => resolve()))
  return address.port
}

describe("empty Redis restart", () => {
  const children: Bun.Subprocess[] = []
  afterEach(async () => {
    for (const child of children.splice(0)) {
      if (child.exitCode === null) child.kill("SIGTERM")
      await child.exited
    }
  })

  it.skipIf(!redisExecutable)("keeps concurrent startup waiting and isolates a bad readiness observer", async () => {
    const port = await unusedLoopbackPort()
    const url = `redis://127.0.0.1:${port}`
    const messaging = new InternalMessagingService(url)
    let survivingObserverCalls = 0
    let survivingContinuityCalls = 0
    messaging.onReady(() => {
      throw new Error("intentional observer failure")
    })
    messaging.onReady(() => {
      survivingObserverCalls++
    })
    messaging.onContinuityLost(() => {
      throw new Error("intentional observer failure")
    })
    messaging.onContinuityLost(() => {
      survivingContinuityCalls++
    })

    let firstSettled = false
    let secondSettled = false
    const first = messaging.start().finally(() => {
      firstSettled = true
    })
    const second = messaging.start().finally(() => {
      secondSettled = true
    })
    await Bun.sleep(20)
    expect(firstSettled).toBe(false)
    expect(secondSettled).toBe(false)

    const redis = Bun.spawn({
      cmd: [redisExecutable!, "--bind", "127.0.0.1", "--port", String(port), "--save", "", "--appendonly", "no"],
      stdout: "ignore", stderr: "ignore",
    })
    children.push(redis)
    try {
      await Promise.all([first, second])
      expect(messaging.health).toBe("ready")
      expect(survivingObserverCalls).toBe(1)
      redis.kill("SIGTERM")
      await redis.exited
      await waitUntil(() => survivingContinuityCalls === 1)
    } finally {
      await messaging.close()
    }
  }, 10_000)

  it.skipIf(!redisExecutable)("rebuilds local registrations and drops unavailable desktop activity", async () => {
    const port = await unusedLoopbackPort()
    const url = `redis://127.0.0.1:${port}`
    const launch = () => {
      const child = Bun.spawn({
        cmd: [redisExecutable!, "--bind", "127.0.0.1", "--port", String(port), "--save", "", "--appendonly", "no"],
        stdout: "ignore", stderr: "ignore",
      })
      children.push(child)
      return child
    }
    let redis = launch()
    const a = new InternalMessagingService(url)
    const b = new InternalMessagingService(url)
    const directoryA = new ConnectionDirectory(a)
    const directoryB = new ConnectionDirectory(b)
    const removeReadyA = a.onReady(() => { void directoryA.recoverFromBrokerRestart() })
    const removeReadyB = b.onReady(() => { void directoryB.recoverFromBrokerRestart() })
    try {
      await Promise.all([a.start(), b.start()])
      await waitUntil(() => a.health === "ready" && b.health === "ready")
      const userId = 930_000 + port
      directoryA.register({ connectionId: "a", userId, sessionId: 11, clientType: "macos", isBot: false })
      directoryB.register({ connectionId: "b", userId, sessionId: 11, clientType: "macos", isBot: false })
      await Promise.all([directoryA.rebuild(), directoryB.rebuild()])
      await waitUntil(async () => {
        const view = await directoryA.list(userId)
        return view.status === "available" && view.connections.length === 2
      })
      expect(await a.recordDesktopActivity(userId, 22)).toBe(true)
      expect(await b.hasDesktopActivity(userId, 22)).toBe(true)

      redis.kill("SIGTERM")
      await redis.exited
      expect(await a.recordDesktopActivity(userId, 23)).toBe(false)
      expect(await b.hasDesktopActivity(userId, 23)).toBeUndefined()
      expect((await directoryA.list(userId)).status).toBe("unavailable")

      redis = launch()
      await waitUntil(() => a.health === "ready" && b.health === "ready")
      await waitUntil(async () => {
        const view = await directoryA.list(userId)
        return view.status === "available" && view.connections.length === 2
      })
      const rebuilt = await directoryA.list(userId)
      expect(rebuilt.status).toBe("available")
      if (rebuilt.status === "available") expect(rebuilt.complete).toBe(false)
      expect(await b.hasDesktopActivity(userId, 22)).toBe(false)
      expect(await b.hasDesktopActivity(userId, 23)).toBe(false)
    } finally {
      removeReadyA()
      removeReadyB()
      await Promise.all([directoryA.shutdown(), directoryB.shutdown()])
      await Promise.all([a.close(), b.close()])
    }
  }, 15_000)
})
