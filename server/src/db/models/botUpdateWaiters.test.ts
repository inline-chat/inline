import { describe, expect, test } from "bun:test"
import { createBotUpdateWaiters } from "./botUpdateWaiters"

describe("bot update waiters", () => {
  test("does not lose a wake between subscribing and waiting", async () => {
    const waiters = createBotUpdateWaiters()
    const waiter = waiters.subscribe(1)
    waiters.wake(1)
    await waiter.wait(1_000)
    waiter.close()
  })

  test("isolates bots and removes an aborted waiter", async () => {
    const waiters = createBotUpdateWaiters()
    const controller = new AbortController()
    const first = waiters.subscribe(1, controller.signal)
    let finished = false
    const waiting = first.wait(1_000).then(() => { finished = true })
    waiters.wake(2)
    await Bun.sleep(10)
    expect(finished).toBeFalse()
    controller.abort()
    await waiting

    const second = waiters.subscribe(1)
    waiters.wake(1)
    await second.wait(1_000)
    second.close()
  })

  test("resumes for a database fallback when no local update is signaled", async () => {
    const waiters = createBotUpdateWaiters()
    const waiter = waiters.subscribe(1)
    const started = Date.now()
    await waiter.wait(20)
    expect(Date.now() - started).toBeGreaterThanOrEqual(15)
    waiter.close()
  })

  test("wakes all waiting bots for shutdown", async () => {
    const waiters = createBotUpdateWaiters()
    const first = waiters.subscribe(1)
    const second = waiters.subscribe(2)
    waiters.wakeAll()
    await Promise.all([first.wait(1_000), second.wait(1_000)])
    first.close()
    second.close()
  })
})
