import { InlineID } from "./id"
import { it, expect, setSystemTime } from "bun:test"

it("should generate an id", async () => {
  expect(await InlineID.shared.generate()).toBeGreaterThan(100000n)
})

it("can generate 20000 different ids", async () => {
  let ids = new Set()
  for (let i = 0; i < 20000; i++) {
    ids.add((await InlineID.shared.generate()).toString())
  }
  expect(ids.size).toBe(20000)
})

it("can handle clock drift", async () => {
  await InlineID.shared.generate()
  setSystemTime(Date.now() - 1)
  setTimeout(() => {
    setSystemTime(Date.now() + 1)
  }, 1)
  expect((await InlineID.shared.generate()).toString()).toBeTruthy()
})

it("can produces valid ids", async () => {
  expect(InlineID.isValid(await InlineID.shared.generate())).toBe(true)
})
