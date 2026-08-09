import { expect, test } from "@playwright/test"
import { openDirectCoreHarness } from "../direct-core-harness"

test("recovers durable direct-core state after its page disappears", async ({
  context,
}) => {
  const first = await openDirectCoreHarness(context)
  const firstSnapshot = (await first.evaluate(
    `window.inlineDirectCoreHarness.connect()`,
  )) as { ownerId: string }
  const draft = "Draft surviving direct-owner page loss"
  await first.evaluate(
    `window.inlineDirectCoreHarness.saveDraft(${JSON.stringify(draft)})`,
  )
  expect(
    await first.evaluate(`window.inlineDirectCoreHarness.errors()`),
  ).toEqual([])

  await first.close()

  const recovered = await openDirectCoreHarness(context)
  const recoveredSnapshot = (await recovered.evaluate(`(async () => {
    let snapshot = await window.inlineDirectCoreHarness.connect()
    for (let attempt = 0; attempt < 20 && snapshot.blockingFailure?.code === "owner-unavailable"; attempt += 1) {
      await new Promise((resolve) => setTimeout(resolve, 50))
      snapshot = await window.inlineDirectCoreHarness.retry()
    }
    return snapshot
  })()`)) as { ownerId: string }
  expect(recoveredSnapshot).toMatchObject({
    cacheReady: true,
    phase: "ready",
  })
  expect(recoveredSnapshot.ownerId).not.toBe(firstSnapshot.ownerId)
  await expect(
    recovered.evaluate(`window.inlineDirectCoreHarness.loadDraft()`),
  ).resolves.toBe(draft)
  expect(
    await recovered.evaluate(`window.inlineDirectCoreHarness.errors()`),
  ).toEqual([])

  await recovered.evaluate(`window.inlineDirectCoreHarness.clearDraft()`)
  await recovered.evaluate(`window.inlineDirectCoreHarness.detach()`)
})
