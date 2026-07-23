import { expect, test, type Page } from "@playwright/test"
import type { MessageListBrowserHarness } from "../../../src/testing/benchmarks/MessageListBrowserHarness"
import { resizeObserverErrorSuppressionScript } from "../../../src/platform/browser/BrowserResizeObserverErrors"

declare global {
  interface Window {
    inlineMessageListHarnessReady: Promise<MessageListBrowserHarness>
  }
}

type Metrics = {
  scrollTop: number
  scrollHeight: number
  clientHeight: number
  distanceToBottom: number
}

type Anchor = {
  messageId: string
  top: number
}

const openHarness = async (page: Page) => {
  const errors: string[] = []
  await page.addInitScript({
    content: resizeObserverErrorSuppressionScript,
  })
  page.on("pageerror", (error) => {
    if (
      !error.message.includes(
        "ResizeObserver loop completed with undelivered notifications",
      )
    ) {
      errors.push(error.stack ?? error.message)
    }
  })
  await page.goto("/__inline-harness/message-list")
  await page.waitForFunction(
    () => Boolean(window.inlineMessageListHarnessReady),
  )
  await page.evaluate(async () => {
    await window.inlineMessageListHarnessReady
  })
  return errors
}

const frames = (page: Page, count = 4) =>
  page.evaluate(
    (frameCount) =>
      new Promise<void>((resolve) => {
        const next = () => {
          if (frameCount-- <= 0) {
            resolve()
            return
          }
          requestAnimationFrame(next)
        }
        requestAnimationFrame(next)
      }),
    count,
  )

const metrics = (page: Page) =>
  page.evaluate<Metrics>(async () =>
    (await window.inlineMessageListHarnessReady).metrics(),
  )

const anchor = (page: Page) =>
  page.evaluate<Anchor | undefined>(async () =>
    (await window.inlineMessageListHarnessReady).visibleAnchor(),
  )

const expectBottom = async (page: Page) => {
  await expect.poll(async () => (await metrics(page)).distanceToBottom).toBeLessThanOrEqual(1.5)
  await expect.poll(() =>
    page.evaluate(async () =>
      (await window.inlineMessageListHarnessReady).bottomState(),
    ),
  ).toBe(true)
}

test("keeps measured bottom through viewport and final-row resize", async ({
  page,
}) => {
  const errors = await openHarness(page)
  await expectBottom(page)

  await page.evaluate(async () => {
    (await window.inlineMessageListHarnessReady).resize(320)
  })
  await expectBottom(page)

  await page.evaluate(async () => {
    (await window.inlineMessageListHarnessReady).expandLast()
  })
  await expectBottom(page)

  await page.evaluate(async () => {
    (await window.inlineMessageListHarnessReady).resize(620)
  })
  await expectBottom(page)
  expect(errors).toEqual([])
})

test("reports first layout for a short non-scrolling chat after remount", async ({
  page,
}) => {
  const errors = await openHarness(page)
  await expect.poll(() =>
    page.evaluate(async () =>
      (await window.inlineMessageListHarnessReady).firstLayoutCount(),
    ),
  ).toBe(1)

  await page.evaluate(async () => {
    (await window.inlineMessageListHarnessReady).replaceWithShortAndRemount()
  })

  await expect.poll(() =>
    page.evaluate(async () =>
      (await window.inlineMessageListHarnessReady).firstLayoutCount(),
    ),
  ).toBe(2)
  await expect(page.locator("[data-message-id]")).toHaveCount(5)
  await expectBottom(page)
  expect(errors).toEqual([])
})

test("preserves the browsing anchor across resize, prepend, append, and remount", async ({
  page,
}) => {
  const errors = await openHarness(page)
  await expectBottom(page)
  await page.evaluate(async () => {
    await (await window.inlineMessageListHarnessReady).scrollToRatio(0.45)
  })
  await frames(page)

  let expected = await anchor(page)
  expect(expected).toBeDefined()
  await expect.poll(() =>
    page.evaluate(async () =>
      (await window.inlineMessageListHarnessReady).bottomState(),
    ),
  ).toBe(false)

  await page.evaluate(async (messageId) => {
    (await window.inlineMessageListHarnessReady).expand(messageId)
  }, expected!.messageId)
  await frames(page)
  let current = await anchor(page)
  expect(current?.messageId).toBe(expected!.messageId)
  expect(Math.abs(current!.top - expected!.top)).toBeLessThanOrEqual(1)
  expected = current

  await page.evaluate(async () => {
    (await window.inlineMessageListHarnessReady).setMessageStyle("minimal")
  })
  await frames(page)
  current = await anchor(page)
  expect(current?.messageId).toBe(expected!.messageId)
  expect(Math.abs(current!.top - expected!.top)).toBeLessThanOrEqual(1)
  expected = current

  await page.evaluate(async () => {
    (await window.inlineMessageListHarnessReady).prepend(50)
  })
  await frames(page)
  current = await anchor(page)
  expect(current?.messageId).toBe(expected!.messageId)
  expect(Math.abs(current!.top - expected!.top)).toBeLessThanOrEqual(1)
  expected = current

  await page.evaluate(async () => {
    (await window.inlineMessageListHarnessReady).append(false)
  })
  await frames(page)
  current = await anchor(page)
  expect(current?.messageId).toBe(expected!.messageId)
  expect(Math.abs(current!.top - expected!.top)).toBeLessThanOrEqual(1)
  expected = current

  await page.evaluate(async () => {
    (await window.inlineMessageListHarnessReady).navigateAwayAndBack()
  })
  await frames(page)
  current = await anchor(page)
  expect(current?.messageId).toBe(expected!.messageId)
  expect(Math.abs(current!.top - expected!.top)).toBeLessThanOrEqual(1)
  expect(errors).toEqual([])
})

test("a local optimistic send leaves history with one bounded Virtua scroll", async ({
  page,
}) => {
  const errors = await openHarness(page)
  await expectBottom(page)
  const animation = await page.evaluate(async () => {
    await (await window.inlineMessageListHarnessReady).scrollToRatio(0.35)
    const viewport = document.querySelector<HTMLElement>(
      '[data-inline-message-list="viewport"]',
    )!
    const state = window as typeof window & {
      inlineMessageListScrollEvents?: number
    }
    state.inlineMessageListScrollEvents = 0
    viewport.addEventListener("scroll", () => {
      state.inlineMessageListScrollEvents =
        (state.inlineMessageListScrollEvents ?? 0) + 1
    }, { passive: true })
    ;(await window.inlineMessageListHarnessReady).replaceWithSending()
    const row = document.querySelector<HTMLElement>(
      '[data-inline-optimistic-send="true"]',
    )
    return row
      ? {
          animations: row.getAnimations().length,
          height: row.getBoundingClientRect().height,
        }
      : undefined
  })

  expect(animation).toBeDefined()
  expect(animation!.animations).toBeGreaterThan(0)
  expect(animation!.height).toBeGreaterThan(0)
  await expectBottom(page)
  await frames(page, 10)
  const scrollEvents = await page.evaluate(
    () => (window as typeof window & {
      inlineMessageListScrollEvents?: number
    }).inlineMessageListScrollEvents ?? 0,
  )
  expect(scrollEvents).toBeLessThanOrEqual(4)
  expect(errors).toEqual([])
})

test("a failed outgoing message resends exactly once without losing bottom", async ({
  page,
}) => {
  const errors = await openHarness(page)
  await expectBottom(page)
  await page.evaluate(async () => {
    const harness = await window.inlineMessageListHarnessReady
    harness.replaceWithSending()
    harness.failLast()
  })

  const resend = page.getByRole("button", { name: "Resend message" })
  const failedMessageActions = resend.locator(
    'xpath=ancestor::*[@aria-label="Message actions"][1]',
  )
  await failedMessageActions.click({ button: "right" })
  await expect(
    page.getByRole("menuitem", { name: "Copy Text" }),
  ).toBeVisible()
  await expect(
    page.getByRole("menuitem", { name: "Resend" }),
  ).toBeVisible()
  await expect(
    page.getByRole("menuitem", { name: "Reply" }),
  ).toHaveCount(0)
  await expect(
    page.getByRole("menuitem", { name: "Pin" }),
  ).toHaveCount(0)
  await page.keyboard.press("Escape")

  await expect(resend).toBeVisible()
  await resend.click()

  await expect.poll(() =>
    page.evaluate(async () =>
      (await window.inlineMessageListHarnessReady).resendCount(),
    ),
  ).toBe(1)
  await expect(page.getByLabel("Sending")).toBeVisible()
  await expect(resend).toHaveCount(0)
  await expectBottom(page)
  expect(errors).toEqual([])
})
