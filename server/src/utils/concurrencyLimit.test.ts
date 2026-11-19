import { expect, test } from "bun:test"
import { concurrencyLimit } from "./concurrencyLimit"

test("runs at most the limit at once and starts waiters in order as slots free up", async () => {
  const limit = concurrencyLimit(2)
  const gates = Array.from({ length: 4 }, () => Promise.withResolvers<void>())
  const started: number[] = []
  const runs = gates.map((gate, index) =>
    limit(async () => {
      started.push(index)
      await gate.promise
      return index
    }),
  )

  await Promise.resolve()
  expect(started).toEqual([0, 1])

  gates[1]?.resolve()
  await runs[1]
  await Promise.resolve()
  expect(started).toEqual([0, 1, 2])

  gates[0]?.reject(new Error("failed"))
  await expect(runs[0]).rejects.toThrow("failed")
  await Promise.resolve()
  expect(started).toEqual([0, 1, 2, 3])

  gates[2]?.resolve()
  gates[3]?.resolve()
  expect(await Promise.all(runs.slice(2))).toEqual([2, 3])

  // Every slot was returned: a fresh pair starts immediately.
  const again: number[] = []
  const pair = [limit(async () => again.push(0)), limit(async () => again.push(1))]
  await Promise.all(pair)
  expect(again).toEqual([0, 1])
})
