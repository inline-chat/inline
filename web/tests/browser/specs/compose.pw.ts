import { expect, test, type Page } from "@playwright/test"
import type { InlineComposeBrowserHarness } from "../../../src/testing/compose/InlineComposeBrowserHarnessPage"

declare global {
  interface Window {
    inlineComposeHarnessReady: Promise<InlineComposeBrowserHarness>
  }
}

const openHarness = async (page: Page) => {
  const errors: string[] = []
  page.on("pageerror", (error) => {
    errors.push(error.stack ?? error.message)
  })
  await page.goto("/__inline-harness/compose")
  await page.evaluate(async () => window.inlineComposeHarnessReady)
  return errors
}

test("autofocuses and emits Inline bold/italic protocol entities", async ({
  page,
}) => {
  const errors = await openHarness(page)
  const editor = page.getByRole("textbox", { name: "Message" })
  await expect(editor).toBeFocused()
  await editor.type("Hello")
  await editor.press("Meta+a")
  await editor.press("Meta+b")
  await editor.press("Meta+i")

  await expect.poll(() =>
    page.evaluate(async () =>
      (await window.inlineComposeHarnessReady).document(),
    ),
  ).toMatchObject({
    text: "Hello",
    entities: {
      entities: [
        { type: 5, offset: 0n, length: 5n },
        { type: 6, offset: 0n, length: 5n },
      ],
    },
  })
  expect(errors).toEqual([])
})

test("offers selection-only bold and italic controls", async ({ page }) => {
  const errors = await openHarness(page)
  const editor = page.getByRole("textbox", { name: "Message" })
  await editor.type("Selected")
  await editor.press("Meta+a")
  const toolbar = page.getByRole("toolbar", { name: "Text formatting" })
  await expect(toolbar).toBeVisible()
  await toolbar.getByRole("button", { name: "Bold" }).click()
  await toolbar.getByRole("button", { name: "Italic" }).click()

  await expect.poll(() =>
    page.evaluate(async () =>
      (await window.inlineComposeHarnessReady).document(),
    ),
  ).toMatchObject({
    text: "Selected",
    entities: {
      entities: [
        { type: 5, offset: 0n, length: 8n },
        { type: 6, offset: 0n, length: 8n },
      ],
    },
  })
  expect(errors).toEqual([])
})

test("selects a mention before Enter can submit", async ({ page }) => {
  const errors = await openHarness(page)
  const editor = page.getByRole("textbox", { name: "Message" })
  await editor.type("@den")
  await expect(page.getByRole("option", { name: "Dena Sohrabi" })).toBeVisible()
  await editor.press("Enter")
  await editor.type(" hello")

  const state = await page.evaluate(async () => ({
    document: (await window.inlineComposeHarnessReady).document(),
    submitted: (await window.inlineComposeHarnessReady).submitted(),
  }))
  expect(state.document).toMatchObject({
    text: "@Dena Sohrabi  hello",
    entities: {
      entities: [
        { type: 1, offset: 0n, length: 13n },
      ],
    },
  })
  expect(state.submitted).toEqual([])
  expect(errors).toEqual([])
})

test("keeps Shift-Enter multiline and submits the exact document on Enter", async ({
  page,
}) => {
  const errors = await openHarness(page)
  const editor = page.getByRole("textbox", { name: "Message" })
  await editor.type("first")
  await editor.press("Shift+Enter")
  await editor.type("second")
  await editor.press("Enter")

  await expect.poll(() =>
    page.evaluate(async () =>
      (await window.inlineComposeHarnessReady).submitted(),
    ),
  ).toEqual([{ text: "first\nsecond" }])
  expect(errors).toEqual([])
})

test("pastes plain text without importing clipboard HTML formatting", async ({
  page,
}) => {
  const errors = await openHarness(page)
  const editor = page.getByRole("textbox", { name: "Message" })
  await editor.type("replace me")
  await editor.press("Meta+a")
  await editor.evaluate((element) => {
    const transfer = new DataTransfer()
    transfer.setData("text/plain", "plain\r\ntext")
    transfer.setData("text/html", "<strong>plain</strong><em>text</em>")
    element.dispatchEvent(
      new ClipboardEvent("paste", {
        bubbles: true,
        cancelable: true,
        clipboardData: transfer,
      }),
    )
  })

  await expect.poll(() =>
    page.evaluate(async () =>
      (await window.inlineComposeHarnessReady).document(),
    ),
  ).toEqual({ text: "plain\ntext" })
  expect(errors).toEqual([])
})

test("does not submit an IME composition Enter", async ({ page }) => {
  const errors = await openHarness(page)
  const editor = page.getByRole("textbox", { name: "Message" })
  await editor.type("draft")
  await editor.evaluate((element) => {
    element.dispatchEvent(
      new CompositionEvent("compositionstart", {
        bubbles: true,
        data: "て",
      }),
    )
    element.dispatchEvent(
      new KeyboardEvent("keydown", {
        bubbles: true,
        cancelable: true,
        key: "Enter",
        code: "Enter",
        isComposing: true,
        keyCode: 229,
      }),
    )
    element.dispatchEvent(
      new CompositionEvent("compositionend", {
        bubbles: true,
        data: "て",
      }),
    )
  })

  expect(
    await page.evaluate(async () =>
      (await window.inlineComposeHarnessReady).submitted(),
    ),
  ).toEqual([])
  expect(errors).toEqual([])
})

test("never overwrites local typing with a late restored draft", async ({
  page,
}) => {
  const errors = await openHarness(page)
  const editor = page.getByRole("textbox", { name: "Message" })
  await editor.type("new local text")
  await page.evaluate(async () =>
    (await window.inlineComposeHarnessReady).restore({
      text: "stale persisted text",
    }),
  )

  await expect.poll(() =>
    page.evaluate(async () =>
      (await window.inlineComposeHarnessReady).document(),
    ),
  ).toEqual({ text: "new local text" })
  expect(errors).toEqual([])
})
