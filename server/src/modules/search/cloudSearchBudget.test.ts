import { expect, test } from "bun:test"
import { withCloudSearchBudget } from "./cloudSearchBudget"
import { queryPoolCapacity } from "@in/server/db"

test("only the newest pending request starts, after the previous physical operation settles", async () => {
  const gate = Promise.withResolvers<void>()
  const started: number[] = []
  const first = withCloudSearchBudget(1, 1, undefined, async () => {
    started.push(1)
    await gate.promise
  })
  const firstRejected = first.catch((error) => error)
  const second = withCloudSearchBudget(1, 1, undefined, async () => {
    started.push(2)
  })
  const secondRejected = second.catch((error) => error)
  const third = withCloudSearchBudget(1, 1, undefined, async () => {
    started.push(3)
  })
  expect(await Promise.all([firstRejected, secondRejected])).toMatchObject([{ codeNumber: 408 }, { codeNumber: 408 }])
  expect(started).toEqual([1])
  gate.resolve()
  await third
  expect(started).toEqual([1, 3])
})

test("independent sessions share bounded pool admission and cancellation retains occupied slots", async () => {
  const gate = Promise.withResolvers<void>()
  const controller = new AbortController()
  const capacity = Math.max(1, Math.floor(queryPoolCapacity() / 3))
  const jobs = Array.from({ length: capacity }, (_, session) =>
    withCloudSearchBudget(1, session, controller.signal, () => gate.promise),
  )
  const rejected = jobs.map((job) => job.catch((error) => error))
  await expect(withCloudSearchBudget(2, 99, undefined, async () => 1)).rejects.toMatchObject({ codeNumber: 429 })
  controller.abort()
  for (const error of await Promise.all(rejected)) expect(error).toMatchObject({ codeNumber: 408 })
  await expect(withCloudSearchBudget(2, 99, undefined, async () => 1)).rejects.toMatchObject({ codeNumber: 429 })
  gate.resolve()
  await Promise.resolve()
  expect(await withCloudSearchBudget(2, 99, undefined, async () => 1)).toBe(1)
})
