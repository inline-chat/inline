import { describe, expect, test } from "bun:test"
import {
  BotPresenceHintDispatcher,
  maxConcurrentBotPresenceDeliveries,
  maxRetainedBotPresenceKeys,
} from "./cluster"

const settle = async (condition: () => boolean): Promise<void> => {
  for (let attempt = 0; attempt < 32; attempt++) {
    if (condition()) return
    await Promise.resolve()
  }
  throw new Error("Condition did not settle")
}

const manualTimers = () => {
  let next = 0
  const callbacks = new Map<number, () => void>()
  return {
    runtime: {
      set(callback: () => void) {
        const id = ++next
        callbacks.set(id, callback)
        return id as never
      },
      clear(id: number) {
        callbacks.delete(id)
      },
    },
    get size() { return callbacks.size },
    fireAll() {
      const current = [...callbacks.values()]
      callbacks.clear()
      for (const callback of current) callback()
    },
  }
}

describe("bot presence cluster delivery ownership", () => {
  test("bounds a burst to eight reads while retaining at most one current value per key", async () => {
    const release = Promise.withResolvers<void>()
    let active = 0
    let peak = 0
    const dispatcher = new BotPresenceHintDispatcher(async () => {
      active++
      peak = Math.max(peak, active)
      try { await release.promise } finally { active-- }
      return {}
    })

    const work = Array.from({ length: maxRetainedBotPresenceKeys + 100 }, (_, index) =>
      dispatcher.observe({ userId: index + 1, botUserId: 9, chatId: 11 }),
    )
    await settle(() => dispatcher.diagnostics.active === maxConcurrentBotPresenceDeliveries)

    expect(peak).toBe(maxConcurrentBotPresenceDeliveries)
    expect(dispatcher.diagnostics.retained).toBe(maxRetainedBotPresenceKeys)
    expect(dispatcher.diagnostics.ready).toBe(maxRetainedBotPresenceKeys - maxConcurrentBotPresenceDeliveries)
    expect(dispatcher.diagnostics.dropped).toBe(100)

    const stopping = dispatcher.stop()
    release.resolve()
    await stopping
    await Promise.all(work)
  })

  test("coalesces retries per key and never schedules another retry after stop", async () => {
    const timers = manualTimers()
    let deliveries = 0
    const dispatcher = new BotPresenceHintDispatcher(async () => {
      deliveries++
      return { retryAfterMs: 10 }
    }, timers.runtime as never)

    await dispatcher.observe({ userId: 1, botUserId: 2, chatId: 3 })
    expect(timers.size).toBe(1)

    timers.fireAll()
    await settle(() => deliveries === 2)
    expect(timers.size).toBe(1)

    await dispatcher.stop()
    expect(timers.size).toBe(0)
    timers.fireAll()
    await Promise.resolve()
    expect(deliveries).toBe(2)
  })

  test("stop waits for a held database read before resolving", async () => {
    const entered = Promise.withResolvers<void>()
    const release = Promise.withResolvers<void>()
    const dispatcher = new BotPresenceHintDispatcher(async () => {
      entered.resolve()
      await release.promise
      return { retryAfterMs: 10 }
    })

    const observed = dispatcher.observe({ userId: 1, botUserId: 2, chatId: 3 })
    await entered.promise
    let stopped = false
    const stop = dispatcher.stop().then(() => { stopped = true })
    await Promise.resolve()
    expect(stopped).toBe(false)

    release.resolve()
    await Promise.all([observed, stop])
    expect(dispatcher.diagnostics.retained).toBe(0)
  })
})
