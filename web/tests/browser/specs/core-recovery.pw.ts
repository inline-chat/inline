import { expect, test, type BrowserContext, type Page } from "@playwright/test"

const openFailureHarness = async (
  context: BrowserContext,
): Promise<Page> => {
  const page = await context.newPage()
  await page.goto("/@vite/client")
  await page.evaluate(`(async () => {
    await import("/src/testing/core/InlineCoreFailureBrowserHarnessPage.ts")
    const deadline = performance.now() + 5_000
    while (!window.inlineCoreFailureHarness) {
      if (performance.now() >= deadline) {
        throw new Error("Inline core failure harness did not initialize")
      }
      await new Promise((resolve) => requestAnimationFrame(resolve))
    }
  })()`)
  return page
}

test("recovers durable state only through a new owner after worker termination", async ({
  context,
}) => {
  const page = await openFailureHarness(context)
  const firstOwner = await page.evaluate<string>(
    `window.inlineCoreFailureHarness.connect()`,
  )
  const draft = "Draft surviving SharedWorker termination"
  await page.evaluate(
    `window.inlineCoreFailureHarness.saveDraft(${JSON.stringify(draft)})`,
  )

  const cdp = await context.newCDPSession(page)
  const { targetInfos } = await cdp.send("Target.getTargets")
  const workers = targetInfos.filter(
    (target) =>
      target.type === "shared_worker" &&
      target.url.includes("InlineCore.shared-worker"),
  )
  expect(workers).toHaveLength(1)
  await cdp.send("Target.closeTarget", {
    targetId: workers[0]!.targetId,
  })

  const failure = await page.evaluate<{
    phase: string
    blockingFailure?: {
      code: string
      recoveryAction: string
    }
  }>(`window.inlineCoreFailureHarness.waitForFailure()`)
  expect(failure).toMatchObject({
    phase: "error",
    blockingFailure: {
      code: "owner-unresponsive",
      recoveryAction: "reload",
    },
  })

  const terminalStart = await page.evaluate<{
    code?: string
    message: string
  }>(`window.inlineCoreFailureHarness.startAfterFailure()`)
  expect(terminalStart.code).toBe("owner-failed")

  const recoveredOwner = await page.evaluate<string>(
    `window.inlineCoreFailureHarness.recover()`,
  )
  expect(recoveredOwner).not.toBe(firstOwner)
  await expect(
    page.evaluate<string | undefined>(
      `window.inlineCoreFailureHarness.loadDraft()`,
    ),
  ).resolves.toBe(draft)
  expect(
    await page.evaluate<string[]>(
      `window.inlineCoreFailureHarness.errors()`,
    ),
  ).toEqual([])

  await page.evaluate(`window.inlineCoreFailureHarness.clearDraft()`)
  await page.evaluate(`window.inlineCoreFailureHarness.detach()`)
})
