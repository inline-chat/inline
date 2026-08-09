import type { BrowserContext, Page } from "@playwright/test"

export const openDirectCoreHarness = async (
  context: BrowserContext,
): Promise<Page> => {
  const page = await context.newPage()
  await page.goto("/@vite/client")
  await page.evaluate(`(async () => {
    await import("/src/testing/core/InlineDirectCoreBrowserHarnessPage.ts")
    const deadline = performance.now() + 5_000
    while (!window.inlineDirectCoreHarness) {
      if (performance.now() >= deadline) {
        throw new Error("Inline direct core harness did not initialize")
      }
      await new Promise((resolve) => requestAnimationFrame(resolve))
    }
  })()`)
  return page
}
