import { expect, test, type BrowserContext, type Page } from "@playwright/test"

const openHarnessPage = async (
  context: BrowserContext,
): Promise<Page> => {
  const page = await context.newPage()
  await page.goto("/@vite/client")
  await page.evaluate(`(async () => {
    await import("/src/testing/core/InlineCoreOwnerBrowserHarnessPage.ts")
    const deadline = performance.now() + 5_000
    while (!window.inlineCoreOwnerHarness) {
      if (performance.now() >= deadline) {
        throw new Error("Inline core owner harness did not initialize")
      }
      await new Promise((resolve) => requestAnimationFrame(resolve))
    }
  })()`)
  return page
}

test("owns one durable account core across renderer lifecycles", async ({
  context,
}) => {
  test.setTimeout(50_000)
  const pages: Page[] = []
  const openPage = async () => {
    const page = await openHarnessPage(context)
    pages.push(page)
    return page
  }

  const first = await openPage()
  const second = await openPage()
  const [firstOwner, secondOwner] = await Promise.all([
    first.evaluate<string>(
      `window.inlineCoreOwnerHarness.connect("first-tab")`,
    ),
    second.evaluate<string>(
      `window.inlineCoreOwnerHarness.connect("second-tab")`,
    ),
  ])
  expect(secondOwner).toBe(firstOwner)

  const crossVersionResult = await first.evaluate<string>(
    `window.inlineCoreOwnerHarness.connectDifferentGeneration("future-tab", "future")`,
  )
  expect(crossVersionResult).toContain("owner-failed")
  expect(crossVersionResult).toContain("Another Inline version")

  await Promise.all([
    first.evaluate(
      `window.inlineCoreOwnerHarness.waitForCacheReady("first-tab")`,
    ),
    second.evaluate(
      `window.inlineCoreOwnerHarness.waitForCacheReady("second-tab")`,
    ),
  ])

  const draftText = "Shared browser draft"
  await first.evaluate(
    `window.inlineCoreOwnerHarness.updateDraft("first-tab", ${JSON.stringify(draftText)})`,
  )
  await expect(
    second.evaluate<string | undefined>(
      `window.inlineCoreOwnerHarness.loadDraftText("second-tab")`,
    ),
  ).resolves.toBe(draftText)

  const revision = await second.evaluate<number>(
    `window.inlineCoreOwnerHarness.requestProjection("second-tab")`,
  )
  expect(revision).toBeGreaterThanOrEqual(0)

  await first.evaluate(
    `window.inlineCoreOwnerHarness.detach("first-tab")`,
  )
  const revisionAfterPeerDetach = await second.evaluate<number>(
    `window.inlineCoreOwnerHarness.requestProjection("second-tab")`,
  )
  expect(revisionAfterPeerDetach).toBeGreaterThanOrEqual(revision)

  const third = await openPage()
  await expect(
    third.evaluate<string>(
      `window.inlineCoreOwnerHarness.connect("third-tab")`,
    ),
  ).resolves.toBe(firstOwner)
  await expect(
    third.evaluate<string | undefined>(
      `window.inlineCoreOwnerHarness.loadDraftText("third-tab")`,
    ),
  ).resolves.toBe(draftText)

  await Promise.all([
    second.evaluate(
      `window.inlineCoreOwnerHarness.detach("second-tab")`,
    ),
    third.evaluate(
      `window.inlineCoreOwnerHarness.detach("third-tab")`,
    ),
  ])

  // Exercise the production 30-second idle teardown; no test-only owner
  // timeout is introduced into runtime code.
  await new Promise((resolve) => setTimeout(resolve, 31_500))

  const fourth = await openPage()
  const fourthOwner = await fourth.evaluate<string>(
    `window.inlineCoreOwnerHarness.connect("fourth-tab")`,
  )
  expect(fourthOwner).not.toBe(firstOwner)
  await expect(
    fourth.evaluate<string | undefined>(
      `window.inlineCoreOwnerHarness.loadDraftText("fourth-tab")`,
    ),
  ).resolves.toBe(draftText)

  await fourth.evaluate(
    `window.inlineCoreOwnerHarness.clearDraft("fourth-tab")`,
  )
  await expect(
    fourth.evaluate<string | undefined>(
      `window.inlineCoreOwnerHarness.loadDraftText("fourth-tab")`,
    ),
  ).resolves.toBeUndefined()

  const runtimeErrors = (
    await Promise.all(
      pages.map((page) =>
        page.evaluate<string[]>(
          `window.inlineCoreOwnerHarness.errors()`,
        ),
      ),
    )
  ).flat()
  expect(runtimeErrors).toEqual([])

  await fourth.evaluate(
    `window.inlineCoreOwnerHarness.detach("fourth-tab")`,
  )
})
