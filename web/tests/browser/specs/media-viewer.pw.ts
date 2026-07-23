import { expect, test, type Page } from "@playwright/test"

declare global {
  interface Window {
    inlineMediaPersistenceHarness: {
      seed(): Promise<unknown>
      reopenOffline(): Promise<unknown>
      renderColdPhoto(): unknown
      releaseColdPhoto(): unknown
    }
    inlineMediaPersistenceHarnessReady: boolean
    inlineMediaPersistenceHarnessErrors: string[]
  }
}

const rotatedUrl =
  "https://api.inline.chat/file?id=persistent-photo&exp=2&sig=rotated"

const openCachedPhoto = async (page: Page) => {
  const errors: string[] = []
  page.on("pageerror", (error) => {
    errors.push(error.stack ?? error.message)
  })
  await page.goto("/__inline-harness/media-cache")
  await page.waitForFunction(
    () => window.inlineMediaPersistenceHarnessReady,
  )
  await page.evaluate(async () => {
    await window.inlineMediaPersistenceHarness.seed()
  })
  await page.reload()
  await page.context().setOffline(true)
  await page.waitForFunction(
    () => window.inlineMediaPersistenceHarnessReady,
  )
  await page.evaluate(async () => {
    await window.inlineMediaPersistenceHarness.reopenOffline()
  })
  return errors
}

test("keeps final geometry while cold media advances from Inline's tiny thumbnail to owned bytes", async ({
  page,
}) => {
  const errors: string[] = []
  page.on("pageerror", (error) => {
    errors.push(error.stack ?? error.message)
  })
  await page.goto("/__inline-harness/media-cache")
  await page.waitForFunction(
    () => window.inlineMediaPersistenceHarnessReady,
  )
  await page.evaluate(() => {
    window.inlineMediaPersistenceHarness.renderColdPhoto()
  })

  const source = page.getByRole("button", { name: "Open photo" })
  const tiny = source.locator('img[aria-hidden="true"]')
  await expect(source).toBeVisible()
  await expect(tiny).toBeVisible()
  await expect(tiny).toHaveAttribute("src", /^data:image\/jpeg;base64,/)
  await expect.poll(() =>
    tiny.evaluate((image: HTMLImageElement) => ({
      complete: image.complete,
      width: image.naturalWidth,
      height: image.naturalHeight,
    })),
  ).toEqual({ complete: true, width: 40, height: 25 })
  await expect(source.getByAltText("Photo")).toHaveCount(0)

  const before = await source.boundingBox()
  expect(before).not.toBeNull()
  expect({ width: before?.width, height: before?.height }).toEqual({
    width: 320,
    height: 240,
  })

  await source.click()
  const coldViewer = page.getByRole("dialog", {
    name: "Photo viewer",
  })
  await expect(coldViewer).toBeVisible()
  await expect(
    coldViewer.getByRole("button", { name: "Download media" }),
  ).toBeDisabled()
  await coldViewer
    .getByRole("button", { name: "Close media viewer" })
    .click()
  await expect(coldViewer).toBeHidden()

  await page.evaluate(() => {
    window.inlineMediaPersistenceHarness.releaseColdPhoto()
  })
  const photo = source.getByAltText("Photo")
  await expect(photo).toBeVisible()
  await expect(photo).toHaveAttribute("src", /^blob:/)
  await expect.poll(() =>
    photo.evaluate((image: HTMLImageElement) => ({
      complete: image.complete,
      width: image.naturalWidth,
      height: image.naturalHeight,
    })),
  ).toEqual({ complete: true, width: 1, height: 1 })
  expect(await source.boundingBox()).toEqual(before)
  await expect(tiny).toBeVisible()
  expect(
    await page.evaluate(
      () => window.inlineMediaPersistenceHarnessErrors,
    ),
  ).toEqual([])
  expect(errors).toEqual([])
})

test("opens and closes cached media from its source without another request", async ({
  page,
}) => {
  const errors = await openCachedPhoto(page)
  const source = page.getByRole("button", { name: "Open photo" })
  const before = await source.boundingBox()
  expect(before).not.toBeNull()

  await source.click()
  const dialog = page.getByRole("dialog", { name: "Photo viewer" })
  await expect(dialog).toBeVisible()
  await expect(page.locator("body")).toHaveCSS("overflow", "hidden")
  const close = dialog.getByRole("button", { name: "Close media viewer" })
  const download = dialog.getByRole("button", { name: "Download media" })
  await expect(close).toBeFocused()
  await page.keyboard.press("Tab")
  await expect(download).toBeFocused()
  await page.keyboard.press("Shift+Tab")
  await expect(close).toBeFocused()

  const viewedPhoto = dialog.getByAltText("Photo")
  await expect.poll(async () => {
    const rect = await viewedPhoto.boundingBox()
    return rect && {
      left: Math.round(rect.x),
      top: Math.round(rect.y),
      width: Math.round(rect.width),
      height: Math.round(rect.height),
    }
  }).toEqual({ left: 240, top: 60, width: 800, height: 600 })

  expect(
    await page.evaluate((url) =>
      performance
        .getEntriesByType("resource")
        .filter((entry) => entry.name === url).length,
    rotatedUrl),
  ).toBe(0)

  await page.keyboard.press("Escape")
  await expect(dialog).toBeHidden()
  await expect(source).toBeFocused()
  await expect(page.locator("body")).not.toHaveCSS("overflow", "hidden")
  expect(await source.boundingBox()).toEqual(before)
  expect(
    await page.evaluate(
      () => window.inlineMediaPersistenceHarnessErrors,
    ),
  ).toEqual([])
  expect(errors).toEqual([])
})
