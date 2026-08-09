import { expect, test } from "@playwright/test"
import { openDirectCoreHarness } from "../direct-core-harness"

test("allows one direct account owner and fails the second tab closed", async ({
  context,
}) => {
  const first = await openDirectCoreHarness(context)
  const second = await openDirectCoreHarness(context)

  const firstSnapshot = (await first.evaluate(
    `window.inlineDirectCoreHarness.connect()`,
  )) as { ownerId: string }
  expect(firstSnapshot).toMatchObject({
    cacheReady: true,
    phase: "ready",
  })
  expect(
    await first.evaluate(`window.inlineDirectCoreHarness.stats()`),
  ).toEqual({ storageOpens: 1, realtimeStarts: 1 })

  const secondSnapshot = await second.evaluate(
    `window.inlineDirectCoreHarness.connect()`,
  )
  expect(secondSnapshot).toMatchObject({
    cacheReady: false,
    phase: "error",
    blockingFailure: { code: "owner-unavailable" },
  })
  expect(
    await second.evaluate(`window.inlineDirectCoreHarness.stats()`),
  ).toEqual({ storageOpens: 0, realtimeStarts: 0 })

  const draft = "Durable single-owner browser draft"
  await first.evaluate(
    `window.inlineDirectCoreHarness.saveDraft(${JSON.stringify(draft)})`,
  )
  await first.evaluate(`window.inlineDirectCoreHarness.detach()`)

  const recoveredSnapshot = (await second.evaluate(
    `window.inlineDirectCoreHarness.retry()`,
  )) as { ownerId: string }
  expect(recoveredSnapshot).toMatchObject({
    cacheReady: true,
    phase: "ready",
  })
  expect(recoveredSnapshot.ownerId).not.toBe(firstSnapshot.ownerId)
  await expect(
    second.evaluate(`window.inlineDirectCoreHarness.loadDraft()`),
  ).resolves.toBe(draft)

  const cdp = await context.newCDPSession(second)
  const { targetInfos } = await cdp.send("Target.getTargets")
  expect(
    targetInfos.filter((target) => target.type === "shared_worker"),
  ).toEqual([])
  expect(
    await Promise.all([
      first.evaluate(`window.inlineDirectCoreHarness.errors()`),
      second.evaluate(`window.inlineDirectCoreHarness.errors()`),
    ]),
  ).toEqual([[], []])

  await second.evaluate(`window.inlineDirectCoreHarness.clearDraft()`)
  await second.evaluate(`window.inlineDirectCoreHarness.detach()`)
})
