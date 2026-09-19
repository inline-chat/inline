import { expect, test } from "bun:test"
import { trackBackgroundWork } from "./background"

test("drain waits for real work including a child scheduled by its parent", async () => {
  const background = trackBackgroundWork()
  const childStarted = Promise.withResolvers<void>()
  const releaseChild = Promise.withResolvers<void>()
  const child = background.wrap(async () => {
    childStarted.resolve()
    await releaseChild.promise
  })
  const parent = background.wrap(async () => { await Promise.resolve(); void child() })
  void parent()
  let finished = false
  const drain = background.drain().then(() => { finished = true })
  await childStarted.promise
  expect(finished).toBe(false)
  releaseChild.resolve()
  await drain
  expect(finished).toBe(true)
})

test("drain surfaces a background failure even when its caller catches it", async () => {
  const background = trackBackgroundWork()
  const work = background.wrap(async () => { throw new Error("background write failed") })
  await work().catch(() => {})
  await expect(background.drain()).rejects.toMatchObject({
    errors: [new Error("background write failed")],
  })
  await background.drain()
})
