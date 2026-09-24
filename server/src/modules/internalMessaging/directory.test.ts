import { describe, expect, it } from "bun:test"
import {
  ConnectionDirectory,
  maxConcurrentDirectoryWrites,
  maxPendingDirectoryWrites,
} from "./directory"
import type { InternalMessagingService } from "./service"

const schedulerState = (directory: ConnectionDirectory) => ({
  active: Reflect.get(directory, "activeWrites") as number,
  pending: (Reflect.get(directory, "pendingWrites") as Map<unknown, unknown>).size,
  writes: (Reflect.get(directory, "writes") as Map<unknown, unknown>).size,
})

describe("connection directory reconstruction", () => {
  it("marks a broker-backed view incomplete while its local registration is pending", async () => {
    let finishRegistration: (() => void) | undefined
    const registration = new Promise<void>((resolve) => { finishRegistration = resolve })
    let evalCalls = 0
    const messaging = {
      bootId: "test-boot",
      key: (suffix: string) => `test:${suffix}`,
      sendCommand: async (name: string) => {
        if (name === "EVAL" && ++evalCalls === 1) {
          await registration
          return 1
        }
        if (name === "ZRANGEBYSCORE") return []
        return 1
      },
    } as unknown as InternalMessagingService
    const directory = new ConnectionDirectory(messaging)
    directory.register({ connectionId: "c1", userId: 7, sessionId: 11, clientType: "macos", isBot: false })
    expect(await directory.list(7)).toEqual({ status: "available", complete: false, connections: [] })
    finishRegistration?.()
    await directory.rebuild()
    expect(await directory.list(7)).toEqual({ status: "available", complete: true, connections: [] })
    await directory.shutdown()
  })

  it("bounds renewal and drains a coalesced rebuild before shutdown resolves", async () => {
    let active = 0
    let maximumActive = 0
    let release!: () => void
    const gate = new Promise<void>((resolve) => { release = resolve })
    let allWorkersStarted!: () => void
    const workersStarted = new Promise<void>((resolve) => { allWorkersStarted = resolve })
    const messaging = {
      bootId: "test-boot",
      key: (suffix: string) => `test:${suffix}`,
      sendCommand: async (name: string) => {
        if (name !== "EVAL") return []
        active++
        maximumActive = Math.max(maximumActive, active)
        if (maximumActive === maxConcurrentDirectoryWrites) {
          allWorkersStarted()
        }
        await gate
        active--
        return 1
      },
    } as unknown as InternalMessagingService
    const directory = new ConnectionDirectory(messaging)
    const count = maxConcurrentDirectoryWrites + 9

    for (let index = 0; index < count; index++) {
      directory.register({
        connectionId: `connection:${index}`,
        userId: index + 1,
        sessionId: index + 1,
        clientType: "macos",
        isBot: false,
      })
    }

    await workersStarted
    let rebuildFinished = false
    const rebuilding = directory.rebuild().then(() => { rebuildFinished = true })
    const shuttingDown = directory.shutdown()
    release()
    await shuttingDown

    expect(maximumActive).toBe(maxConcurrentDirectoryWrites)
    expect(active).toBe(0)
    expect(rebuildFinished).toBeTrue()
    await rebuilding
  })

  it("drops excess advisory writes and keeps the directory incomplete until their TTL window", async () => {
    let release!: () => void
    const gate = new Promise<void>((resolve) => { release = resolve })
    const messaging = {
      bootId: "test-boot",
      key: (suffix: string) => `test:${suffix}`,
      sendCommand: async (name: string) => {
        if (name !== "EVAL") return []
        await gate
        return 1
      },
    } as unknown as InternalMessagingService
    const directory = new ConnectionDirectory(messaging)

    for (let index = 0; index < maxConcurrentDirectoryWrites + maxPendingDirectoryWrites + 1; index++) {
      directory.register({
        connectionId: `overflow:${index}`,
        userId: index + 1,
        sessionId: index + 1,
        clientType: "macos",
        isBot: false,
      })
    }

    expect(await directory.list(1)).toEqual({
      status: "available",
      complete: false,
      connections: [],
    })
    release()
    await directory.shutdown()
  })

  it("coalesces 10,000 same-key transitions into one retained state and one ordered follow-up", async () => {
    let active = 0
    let maximumActive = 0
    let startFirst!: () => void
    const firstStarted = new Promise<void>((resolve) => { startFirst = resolve })
    let release!: () => void
    const gate = new Promise<void>((resolve) => { release = resolve })
    const commands: ("register" | "remove")[] = []
    const messaging = {
      bootId: "test-boot",
      key: (suffix: string) => `test:${suffix}`,
      sendCommand: async (name: string, args: string[]) => {
        if (name !== "EVAL") return []
        commands.push(args[0]?.includes("SET") ? "register" : "remove")
        active++
        maximumActive = Math.max(maximumActive, active)
        try {
          if (commands.length === 1) {
            startFirst()
            await gate
          }
          return 1
        } finally {
          active--
        }
      },
    } as unknown as InternalMessagingService
    const directory = new ConnectionDirectory(messaging)
    const input = { connectionId: "same-key", userId: 7, sessionId: 11, clientType: "macos", isBot: false }

    directory.register(input)
    await firstStarted
    for (let index = 1; index < 10_000; index++) {
      if (index % 2 === 1) directory.unregister(input.connectionId)
      else directory.register(input)
    }

    expect(schedulerState(directory)).toEqual({ active: 1, pending: 0, writes: 1 })
    release()
    await directory.shutdown()

    expect(maximumActive).toBe(1)
    expect(commands).toEqual(["register", "remove"])
    expect(schedulerState(directory)).toEqual({ active: 0, pending: 0, writes: 0 })
  })

  it("caps distinct-key churn before retaining scheduler state and drains every removal", async () => {
    let active = 0
    let maximumActive = 0
    let startWorkers!: () => void
    const workersStarted = new Promise<void>((resolve) => { startWorkers = resolve })
    let release!: () => void
    const gate = new Promise<void>((resolve) => { release = resolve })
    const messaging = {
      bootId: "test-boot",
      key: (suffix: string) => `test:${suffix}`,
      sendCommand: async (name: string) => {
        if (name !== "EVAL") return []
        active++
        maximumActive = Math.max(maximumActive, active)
        if (maximumActive === maxConcurrentDirectoryWrites) startWorkers()
        try {
          await gate
          return 1
        } finally {
          active--
        }
      },
    } as unknown as InternalMessagingService
    const directory = new ConnectionDirectory(messaging)
    const count = maxConcurrentDirectoryWrites + maxPendingDirectoryWrites + 1_000

    for (let index = 0; index < count; index++) {
      directory.register({
        connectionId: `distinct:${index}`,
        userId: index + 1,
        sessionId: index + 1,
        clientType: "macos",
        isBot: false,
      })
    }

    await workersStarted
    expect(schedulerState(directory)).toEqual({
      active: maxConcurrentDirectoryWrites,
      pending: maxPendingDirectoryWrites,
      writes: maxConcurrentDirectoryWrites + maxPendingDirectoryWrites,
    })
    expect(await directory.list(1)).toEqual({ status: "available", complete: false, connections: [] })

    const shutdown = directory.shutdown()
    release()
    await shutdown

    expect(maximumActive).toBeLessThanOrEqual(maxConcurrentDirectoryWrites)
    expect(schedulerState(directory)).toEqual({ active: 0, pending: 0, writes: 0 })
  })

  it("orders a removal after an active registration when recovery rebuild overlaps disconnect", async () => {
    let startFirst!: () => void
    const firstStarted = new Promise<void>((resolve) => { startFirst = resolve })
    let release!: () => void
    const gate = new Promise<void>((resolve) => { release = resolve })
    const commands: ("register" | "remove")[] = []
    const messaging = {
      bootId: "test-boot",
      key: (suffix: string) => `test:${suffix}`,
      sendCommand: async (name: string, args: string[]) => {
        if (name !== "EVAL") return []
        commands.push(args[0]?.includes("SET") ? "register" : "remove")
        if (commands.length === 1) {
          startFirst()
          await gate
        }
        return 1
      },
    } as unknown as InternalMessagingService
    const directory = new ConnectionDirectory(messaging)
    const input = { connectionId: "recovery-race", userId: 31, sessionId: 41, clientType: "macos", isBot: false }

    directory.register(input)
    await firstStarted
    const recovering = directory.recoverFromBrokerRestart()
    directory.unregister(input.connectionId)
    release()
    await recovering

    expect(commands).toEqual(["register", "remove"])
    expect(directory.hasLocalConnection(input.connectionId, input.userId, input.sessionId)).toBe(false)
    await directory.shutdown()
  })

  it("can schedule renewal again after shutdown and resume", async () => {
    const messaging = {
      bootId: "test-boot",
      key: (suffix: string) => `test:${suffix}`,
      sendCommand: async () => 1,
    } as unknown as InternalMessagingService
    const directory = new ConnectionDirectory(messaging)

    directory.register({
      connectionId: "before-shutdown",
      userId: 1,
      sessionId: 1,
      clientType: "macos",
      isBot: false,
    })
    expect(Reflect.get(directory, "timer")).toBeDefined()

    await directory.shutdown()
    expect(Reflect.get(directory, "timer")).toBeUndefined()

    directory.resume()
    directory.register({
      connectionId: "after-resume",
      userId: 2,
      sessionId: 2,
      clientType: "macos",
      isBot: false,
    })
    expect(Reflect.get(directory, "timer")).toBeDefined()

    await directory.shutdown()
  })

  it("keeps the directory incomplete after an unavailable Redis script result", async () => {
    const messaging = {
      bootId: "test-boot",
      key: (suffix: string) => `test:${suffix}`,
      sendCommand: async (name: string) => name === "EVAL" ? undefined : [],
    } as unknown as InternalMessagingService
    const directory = new ConnectionDirectory(messaging)

    directory.register({
      connectionId: "unavailable-write",
      userId: 1,
      sessionId: 1,
      clientType: "macos",
      isBot: false,
    })
    await directory.rebuild()

    expect(await directory.list(1)).toEqual({
      status: "available",
      complete: false,
      connections: [],
    })
    await directory.shutdown()
  })
})
