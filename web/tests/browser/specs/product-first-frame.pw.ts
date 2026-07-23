import { expect, test, type BrowserContext, type Page } from "@playwright/test"

type ProductFrame = {
  path: string
  sidebar: string
  detail: string
  preparedChat: string | null
  messageCount: string | null
  photoSource: string | null
  photoWidth: number | null
  photoHeight: number | null
}

type ProductRouteSeed = {
  accountId: string
  alphaChatId: string
  betaChatId: string
  alphaPath: string
  betaPath: string
  alphaRestoreMessageId: string
  alphaNewestMessageId: string
  alphaPhotoMediaKey: string
  alphaPhotoRemoteUrl: string
  betaNewestMessageId: string
  persistedMessagesPerChat: number
}

type VisibleMessageAnchor = {
  messageId: string
  top: number
}

const installFirstFrameTrace = async (context: BrowserContext) => {
  await context.addInitScript(() => {
    Object.defineProperty(window.navigator, "onLine", {
      configurable: true,
      get: () => false,
    })

    const frames: ProductFrame[] = []
    let scheduled = false
    const sample = () => {
      scheduled = false
      const sidebar = document.querySelector<HTMLElement>(
        "[data-inline-sidebar]",
      )
      const detail = document.querySelector<HTMLElement>(
        "[data-inline-app-detail]",
      )
      if (!sidebar || !detail) return
      const presentation = detail.querySelector<HTMLElement>(
        "[data-inline-route-presentation]",
      )
      const photo = detail.querySelector<HTMLImageElement>('img[alt="Photo"]')
      const photoFrame = photo?.closest<HTMLElement>(
        'button[aria-label="Open photo"]',
      )
      const photoRect = photoFrame?.getBoundingClientRect()
      const frame = {
        path: window.location.pathname,
        sidebar: sidebar.innerText,
        detail: presentation?.innerText ?? detail.innerText,
        preparedChat:
          detail
            .querySelector<HTMLElement>("[data-inline-chat-prepared]")
            ?.dataset.inlineChatPrepared ?? null,
        messageCount:
          detail
            .querySelector<HTMLElement>("[data-inline-chat-message-count]")
            ?.dataset.inlineChatMessageCount ?? null,
        photoSource: photo?.getAttribute("src") ?? null,
        photoWidth: photoRect ? Math.round(photoRect.width) : null,
        photoHeight: photoRect ? Math.round(photoRect.height) : null,
      }
      const previous = frames.at(-1)
      if (
        previous?.path === frame.path &&
        previous.sidebar === frame.sidebar &&
        previous.detail === frame.detail &&
        previous.preparedChat === frame.preparedChat &&
        previous.messageCount === frame.messageCount &&
        previous.photoSource === frame.photoSource &&
        previous.photoWidth === frame.photoWidth &&
        previous.photoHeight === frame.photoHeight
      ) {
        return
      }
      frames.push(frame)
    }
    const schedule = () => {
      if (scheduled) return
      scheduled = true
      requestAnimationFrame(sample)
    }
    const start = () => {
      new MutationObserver(schedule).observe(document.documentElement, {
        subtree: true,
        childList: true,
        characterData: true,
        attributes: true,
      })
      schedule()
    }
    if (document.documentElement) start()
    else window.addEventListener("DOMContentLoaded", start, { once: true })

    Object.assign(window, {
      inlineProductFrameTrace: {
        frames: () => frames.map((frame) => ({ ...frame })),
        reset: () => frames.splice(0, frames.length),
      },
    })
  })
}

const frameTrace = (page: Page) =>
  page.evaluate<ProductFrame[]>(
    `window.inlineProductFrameTrace.frames()`,
  )

const resetFrameTrace = (page: Page) =>
  page.evaluate(`window.inlineProductFrameTrace.reset()`)

const paintFrames = (page: Page, count = 2) =>
  page.evaluate(
    (frameCount) =>
      new Promise<void>((resolve) => {
        let remaining = frameCount
        const next = () => {
          remaining -= 1
          if (remaining <= 0) resolve()
          else requestAnimationFrame(next)
        }
        requestAnimationFrame(next)
      }),
    count,
  )

const focusByTab = async (
  page: Page,
  target: ReturnType<Page["locator"]>,
  options: { backward?: boolean; maximum?: number } = {},
) => {
  await expect(target).toBeVisible()
  const key = options.backward ? "Shift+Tab" : "Tab"
  const maximum = options.maximum ?? 100
  const visited: string[] = []
  for (let index = 0; index < maximum; index += 1) {
    if (await target.evaluate((element) => element === document.activeElement)) {
      return
    }
    await page.keyboard.press(key)
    visited.push(
      await page.evaluate(() =>
        document.activeElement instanceof HTMLElement
          ? document.activeElement.getAttribute("aria-label") ??
            document.activeElement.innerText.slice(0, 40)
          : "unknown",
      ),
    )
  }
  const active = await page.evaluate(() =>
    document.activeElement instanceof HTMLElement
      ? `${document.activeElement.tagName} ${document.activeElement.getAttribute("aria-label") ?? document.activeElement.innerText}`
      : "unknown",
  )
  throw new Error(
    `Keyboard focus did not reach target; active element: ${active}; visited: ${Array.from(new Set(visited)).join(" -> ")}`,
  )
}

const visibleMessageAnchor = (page: Page) =>
  page.evaluate<VisibleMessageAnchor | undefined>(() => {
    const viewport = document.querySelector<HTMLElement>(
      '[data-inline-message-list="viewport"]',
    )
    if (!viewport) return undefined
    const viewportRect = viewport.getBoundingClientRect()
    let partial: VisibleMessageAnchor | undefined
    for (const row of viewport.querySelectorAll<HTMLElement>(
      "[data-message-id]",
    )) {
      const rect = row.getBoundingClientRect()
      if (
        rect.bottom <= viewportRect.top ||
        rect.top >= viewportRect.bottom
      ) {
        continue
      }
      const anchor = {
        messageId: row.dataset.messageId!,
        top: rect.top - viewportRect.top,
      }
      if (rect.top >= viewportRect.top) return anchor
      partial ??= anchor
    }
    return partial
  })

const framesForPath = (
  frames: readonly ProductFrame[],
  path: string,
) => frames.filter((frame) => frame.path === path)

test("opens cached product routes as coherent first frames", async ({
  context,
  page,
}) => {
  test.setTimeout(30_000)
  await installFirstFrameTrace(context)

  const remoteRequests: string[] = []
  const browserErrors: string[] = []
  page.on("request", (request) => {
    const url = new URL(request.url())
    if (url.hostname === "api.inline.chat") {
      remoteRequests.push(`${request.method()} ${url.pathname}`)
    }
  })
  page.on("pageerror", (error) => browserErrors.push(error.message))
  page.on("console", (message) => {
    if (message.type() === "error") browserErrors.push(message.text())
  })

  await page.goto("/login")
  const seed = await page.evaluate<ProductRouteSeed>(`(async () => {
    const harness = await import("/src/testing/product/InlineProductRouteBrowserHarnessPage.ts")
    return await harness.seedInlineProductRouteCache()
  })()`)

  await page.goto("/chats")
  await expect(page.getByText("First cached message").first()).toBeVisible()
  await expect(page.getByText("Second cached message").first()).toBeVisible()

  const chatsFrames = framesForPath(await frameTrace(page), "/chats")
  expect(chatsFrames.length).toBeGreaterThan(0)
  expect(chatsFrames[0]?.sidebar).toContain("Alpha thread")
  expect(chatsFrames[0]?.sidebar).toContain("Beta thread")
  expect(chatsFrames[0]?.detail).toContain("First cached message")
  expect(chatsFrames[0]?.detail).toContain("Second cached message")
  expect(chatsFrames.some((frame) => frame.detail.includes("No chats"))).toBe(false)
  expect(chatsFrames.some((frame) => frame.sidebar.includes("Loading chats"))).toBe(false)

  const allChatsView = page.locator("[data-inline-all-chats-layout]")
  await allChatsView.getByRole("button", { name: "View Options" }).click()
  await page
    .getByRole("menuitemcheckbox", {
      name: "Title and Preview on One Line",
    })
    .click()
  await expect(allChatsView).toHaveAttribute(
    "data-inline-all-chats-layout",
    "titlePreviewLine",
  )

  await page.getByRole("button", { name: "Show Archived Chats" }).click()
  await expect(page).toHaveURL(/\/chats\?archived=true$/)
  await expect(page.getByRole("heading", { name: "Archived Chats" })).toBeVisible()
  await expect(page.getByText("Archived plans")).toBeVisible()
  await expect(page.getByText("Archived launch notes")).toBeVisible()
  await expect(page.getByText("Alpha thread")).toHaveCount(1)
  await page.getByRole("button", { name: "Show Chats" }).click()
  await expect(page).toHaveURL(/\/chats$/)
  await expect(page.getByRole("heading", { name: "Chats" })).toBeVisible()
  await expect(page.getByText("Archived plans")).toHaveCount(0)

  await resetFrameTrace(page)
  await page.locator(`[data-inline-sidebar] a[href="${seed.alphaPath}"]`).click()
  await expect(
    page.locator("[data-inline-app-detail]").getByText("First cached message"),
  ).toBeVisible()
  const alphaFrames = framesForPath(await frameTrace(page), seed.alphaPath)
  expect(alphaFrames.length).toBeGreaterThan(0)
  expect(alphaFrames.some((frame) => frame.detail.includes("Second cached message"))).toBe(false)
  expect(
    alphaFrames
      .filter((frame) => frame.detail.trim().length > 0)
      .every((frame) => frame.detail.includes("First cached message")),
  ).toBe(true)
  expect(alphaFrames.at(-1)?.detail).toContain("Alpha thread")
  expect(alphaFrames.at(-1)?.detail).toContain("First cached message")
  const pinnedMessage = page.getByRole("button", {
    name: "Go to pinned message",
  })
  await expect(pinnedMessage).toBeVisible()
  await expect(pinnedMessage).toContainText("Dena Inline")
  await expect(pinnedMessage).toContainText("Alpha cached message 113")
  await expect(page.getByText("Pinned message unavailable")).toHaveCount(0)
  const exposedAlphaFrames = alphaFrames.filter((frame) =>
    frame.detail.includes("First cached message"),
  )
  expect(exposedAlphaFrames.length).toBeGreaterThan(0)
  expect(
    exposedAlphaFrames.every(
      (frame) =>
        frame.photoSource?.startsWith("blob:") === true &&
        frame.photoWidth === 320 &&
        frame.photoHeight === 240,
    ),
  ).toBe(true)

  const detail = page.locator("[data-inline-app-detail]")
  const photoSource = detail.getByRole("button", { name: "Open photo" })
  const photo = photoSource.getByAltText("Photo")
  await expect(photoSource).toBeVisible()
  await expect(photo).toBeVisible()
  await expect(photo).toHaveAttribute("src", /^blob:/)
  const firstPhotoUrl = await photo.getAttribute("src")
  const firstPhotoFrame = await photoSource.boundingBox()
  expect(firstPhotoFrame).toMatchObject({ width: 320, height: 240 })

  await photoSource.click()
  const viewer = page.getByRole("dialog", { name: "Photo viewer" })
  await expect(viewer).toBeVisible()
  await expect(viewer.getByAltText("Photo")).toHaveAttribute(
    "src",
    firstPhotoUrl!,
  )
  await viewer.getByRole("button", { name: "Close media viewer" }).click()
  await expect(viewer).toBeHidden()
  await expect(photoSource).toBeFocused()

  const back = detail.getByRole("button", { name: "Back" })
  const forward = detail.getByRole("button", { name: "Forward" })
  await expect(back).toBeEnabled()
  await expect(forward).toBeDisabled()
  await back.click()
  await expect(page).toHaveURL(/\/chats$/)
  await expect(page.getByText("First cached message").first()).toBeVisible()
  const allChatsForward = page
    .locator("[data-inline-all-chats-layout]")
    .getByRole("button", { name: "Forward" })
  await expect(allChatsForward).toBeEnabled()
  await allChatsForward.click()
  await expect(page).toHaveURL(seed.alphaPath)
  await expect(photoSource).toBeVisible()

  await resetFrameTrace(page)
  await page.locator(`[data-inline-sidebar] a[href="${seed.betaPath}"]`).click()
  await expect(
    page.locator("[data-inline-app-detail]").getByText("Second cached message"),
  ).toBeVisible()
  const betaFrames = framesForPath(await frameTrace(page), seed.betaPath)
  expect(betaFrames.length).toBeGreaterThan(0)
  expect(betaFrames.some((frame) => frame.detail.includes("First cached message"))).toBe(false)
  expect(
    betaFrames
      .filter((frame) => frame.detail.trim().length > 0)
      .every((frame) => frame.detail.includes("Second cached message")),
  ).toBe(true)
  expect(betaFrames.at(-1)?.detail).toContain("Beta thread")
  expect(betaFrames.at(-1)?.detail).toContain("Second cached message")

  await resetFrameTrace(page)
  await page.goBack()
  await expect(
    page.locator("[data-inline-app-detail]").getByText("First cached message"),
  ).toBeVisible()
  const restoredFrames = framesForPath(await frameTrace(page), seed.alphaPath)
  expect(restoredFrames.length).toBeGreaterThan(0)
  expect(restoredFrames.some((frame) => frame.detail.includes("Second cached message"))).toBe(false)
  expect(
    restoredFrames
      .filter((frame) => frame.detail.trim().length > 0)
      .every((frame) => frame.detail.includes("First cached message")),
  ).toBe(true)
  const restoredPhoto = detail
    .getByRole("button", { name: "Open photo" })
    .getByAltText("Photo")
  await expect(restoredPhoto).toHaveAttribute("src", firstPhotoUrl!)
  expect(
    await page.evaluate((url) =>
      performance
        .getEntriesByType("resource")
        .filter((entry) => entry.name === url).length,
    seed.alphaPhotoRemoteUrl),
  ).toBe(0)

  await resetFrameTrace(page)
  await page.getByRole("button", { name: "Settings" }).click()
  await expect(page.getByText("Mo Cached")).toBeVisible()
  const settingsFrames = framesForPath(await frameTrace(page), "/settings")
  expect(settingsFrames.length).toBeGreaterThan(0)
  expect(settingsFrames[0]?.detail).toContain("Mo Cached")
  expect(settingsFrames[0]?.detail).not.toContain("Loading account")

  expect(remoteRequests).toEqual([])
  expect(browserErrors).toEqual([])
})

test("preserves a bounded real-route window through resize and repeated switching", async ({
  context,
  page,
}) => {
  test.setTimeout(45_000)
  await installFirstFrameTrace(context)

  const remoteRequests: string[] = []
  const browserErrors: string[] = []
  page.on("request", (request) => {
    const url = new URL(request.url())
    if (url.hostname === "api.inline.chat") {
      remoteRequests.push(`${request.method()} ${url.pathname}`)
    }
  })
  page.on("pageerror", (error) => browserErrors.push(error.message))
  page.on("console", (message) => {
    if (message.type() === "error") {
      const location = message.location()
      browserErrors.push(
        `${message.text()} (${location.url}:${location.lineNumber})`,
      )
    }
  })

  await page.goto("/login")
  const seed = await page.evaluate<ProductRouteSeed>(`(async () => {
    const harness = await import("/src/testing/product/InlineProductRouteBrowserHarnessPage.ts")
    return await harness.seedInlineProductRouteCache()
  })()`)
  expect(seed.persistedMessagesPerChat).toBe(120)

  await page.goto("/chats")
  await page.locator(`[data-inline-sidebar] a[href="${seed.alphaPath}"]`).click()
  const detail = page.locator("[data-inline-app-detail]")
  await expect(detail.getByText("First cached message")).toBeVisible()
  await expect(
    detail.locator('[data-inline-chat-message-count="60"]'),
  ).toBeVisible()

  const viewport = detail.locator('[data-inline-message-list="viewport"]')
  await viewport.evaluate((element) => {
    element.dispatchEvent(
      new WheelEvent("wheel", { bubbles: true, deltaY: -1 }),
    )
    element.scrollTop = Math.max(
      0,
      (element.scrollHeight - element.clientHeight) * 0.38,
    )
  })
  await paintFrames(page)
  const beforeResize = await visibleMessageAnchor(page)
  expect(beforeResize).toBeDefined()
  expect(beforeResize?.messageId).not.toBe(seed.alphaNewestMessageId)

  await page.setViewportSize({ width: 1_040, height: 560 })
  await paintFrames(page, 3)
  const afterResize = await visibleMessageAnchor(page)
  expect(afterResize?.messageId).toBe(beforeResize?.messageId)
  expect(Math.abs(afterResize!.top - beforeResize!.top)).toBeLessThanOrEqual(1)

  await page.locator(`[data-inline-sidebar] a[href="${seed.betaPath}"]`).click()
  await expect(detail.getByText("Second cached message")).toBeVisible()
  await expect(
    detail.locator('[data-inline-chat-message-count="60"]'),
  ).toBeVisible()

  await page.goBack()
  await expect(
    detail.locator(`[data-message-id="${beforeResize!.messageId}"]`),
  ).toBeVisible()
  await paintFrames(page, 3)
  const restored = await visibleMessageAnchor(page)
  expect(restored?.messageId).toBe(afterResize?.messageId)
  expect(Math.abs(restored!.top - afterResize!.top)).toBeLessThanOrEqual(1)

  await page.goForward()
  await expect(detail.getByText("Second cached message")).toBeVisible()

  for (let index = 0; index < 3; index += 1) {
    await resetFrameTrace(page)
    await page.locator(`[data-inline-sidebar] a[href="${seed.alphaPath}"]`).click()
    await expect(detail.getByRole("heading", { name: "Alpha thread" })).toBeVisible()
    await expect.poll(() =>
      detail.locator("[data-message-id]").count(),
    ).toBeGreaterThan(0)
    const alphaFrames = framesForPath(
      await frameTrace(page),
      seed.alphaPath,
    )
    expect(
      alphaFrames.some((frame) =>
        frame.detail.includes("Beta cached message"),
      ),
    ).toBe(false)

    await resetFrameTrace(page)
    await page.locator(`[data-inline-sidebar] a[href="${seed.betaPath}"]`).click()
    await expect(detail.getByRole("heading", { name: "Beta thread" })).toBeVisible()
    await expect.poll(() =>
      detail.locator("[data-message-id]").count(),
    ).toBeGreaterThan(0)
    const betaFrames = framesForPath(
      await frameTrace(page),
      seed.betaPath,
    )
    expect(
      betaFrames.some((frame) =>
        frame.detail.includes("Alpha cached message"),
      ),
    ).toBe(false)
  }

  expect(remoteRequests).toEqual([])
  expect(browserErrors).toEqual([])
})

test("reloads a cached chat offline and persists logout", async ({
  context,
  page,
}) => {
  test.setTimeout(30_000)
  await installFirstFrameTrace(context)

  const remoteRequests: string[] = []
  const browserErrors: string[] = []
  page.on("request", (request) => {
    const url = new URL(request.url())
    if (url.hostname === "api.inline.chat") {
      remoteRequests.push(`${request.method()} ${url.pathname}`)
    }
  })
  page.on("pageerror", (error) => browserErrors.push(error.message))
  page.on("console", (message) => {
    if (message.type() === "error") browserErrors.push(message.text())
  })

  await page.goto("/login")
  const seed = await page.evaluate<ProductRouteSeed>(`(async () => {
    const harness = await import("/src/testing/product/InlineProductRouteBrowserHarnessPage.ts")
    return await harness.seedInlineProductRouteCache()
  })()`)

  await page.goto(seed.alphaPath)
  const detail = page.locator("[data-inline-app-detail]")
  await expect(detail.getByText("First cached message")).toBeVisible()
  await expect(detail.getByAltText("Photo")).toHaveAttribute("src", /^blob:/)

  await page.reload()
  await expect(detail.getByText("First cached message")).toBeVisible()
  await expect(detail.getByAltText("Photo")).toHaveAttribute("src", /^blob:/)
  const reloadFrames = framesForPath(await frameTrace(page), seed.alphaPath)
  expect(reloadFrames.length).toBeGreaterThan(0)
  const partialReloadFrames = reloadFrames
    .filter((frame) => frame.detail.trim().length > 0)
    .filter((frame) => !frame.detail.includes("First cached message"))
  expect(
    partialReloadFrames,
    "cached reload must not expose a partial chat frame",
  ).toEqual([])
  expect(reloadFrames.some((frame) => frame.detail.includes("No messages"))).toBe(false)
  expect(reloadFrames.some((frame) => frame.detail.includes("Loading messages"))).toBe(false)
  expect(reloadFrames.some((frame) => frame.detail.includes("Second cached message"))).toBe(false)
  expect(
    reloadFrames
      .filter((frame) => frame.detail.includes("First cached message"))
      .every((frame) => frame.photoSource?.startsWith("blob:") === true),
  ).toBe(true)

  await page.getByRole("button", { name: "Settings" }).click()
  await expect(page.getByText("Mo Cached")).toBeVisible()
  await page.getByRole("button", { name: "Log Out" }).click()
  await expect(page).toHaveURL("/login")
  await expect(
    page.getByRole("heading", { name: "Welcome to Inline" }),
  ).toBeVisible()

  const authAfterLogout = await page.evaluate(`(async () => {
    const harness = await import("/src/testing/product/InlineProductRouteBrowserHarnessPage.ts")
    return await harness.readInlineProductRouteAuthState()
  })()`)
  expect(authAfterLogout).toEqual({
    status: "unauthenticated",
    isLoggedIn: false,
  })

  await page.reload()
  await expect(page).toHaveURL("/login")
  await expect(
    page.getByRole("heading", { name: "Welcome to Inline" }),
  ).toBeVisible()
  expect(remoteRequests).toEqual([])
  expect(browserErrors).toEqual([])
})

test("accepts primary dialog actions locally while offline", async ({
  context,
  page,
}) => {
  test.setTimeout(30_000)
  await installFirstFrameTrace(context)

  const remoteRequests: string[] = []
  const browserErrors: string[] = []
  page.on("request", (request) => {
    const url = new URL(request.url())
    if (url.hostname === "api.inline.chat") {
      remoteRequests.push(`${request.method()} ${url.pathname}`)
    }
  })
  page.on("pageerror", (error) => browserErrors.push(error.message))
  page.on("console", (message) => {
    if (message.type() === "error") browserErrors.push(message.text())
  })

  await page.goto("/login")
  const seed = await page.evaluate<ProductRouteSeed>(`(async () => {
    const harness = await import("/src/testing/product/InlineProductRouteBrowserHarnessPage.ts")
    return await harness.seedInlineProductRouteCache()
  })()`)
  await page.goto(seed.alphaPath)
  await expect(
    page.locator("[data-inline-app-detail]").getByText("First cached message"),
  ).toBeVisible()

  const alphaRow = page.locator(
    `[data-inline-sidebar-chat-id="${seed.alphaChatId}"]`,
  )
  await expect.poll(async () => {
    const state = await page.evaluate((chatId) => {
      const row = document.querySelector<HTMLElement>(
        `[data-inline-sidebar-chat-id="${chatId}"]`,
      )
      const viewport = document.querySelector<HTMLElement>(
        '[data-inline-message-list="viewport"]',
      )
      const chat = document.querySelector<HTMLElement>(
        "[data-inline-chat-active]",
      )
      return {
        unread: row?.dataset.inlineDialogUnread,
        visible: document.visibilityState,
        focused: document.hasFocus(),
        bottom: viewport
          ? Math.round(
              viewport.scrollHeight -
              viewport.scrollTop -
              viewport.clientHeight,
            )
          : null,
        logicalBottom: viewport?.dataset.inlineLogicalBottom,
        hookActive: chat?.dataset.inlineChatActive,
        hookAtBottom: chat?.dataset.inlineChatAtBottom,
        hookNeedsRead: chat?.dataset.inlineChatNeedsRead,
        latestMessageId: chat?.dataset.inlineChatLatestMessageId,
      }
    }, seed.alphaChatId)
    return { ...state, browserErrors: [...browserErrors] }
  }).toMatchObject({
    unread: "false",
    visible: "visible",
    focused: true,
    bottom: 0,
    logicalBottom: "true",
    hookActive: "true",
    hookAtBottom: "true",
    hookNeedsRead: "false",
    latestMessageId: expect.any(String),
    browserErrors: [],
  })

  await page.getByRole("button", { name: "More" }).click()
  await page.getByRole("menuitem", { name: "Pin", exact: true }).click()
  await expect(alphaRow).toHaveAttribute("data-inline-dialog-pinned", "true")

  await page.getByRole("button", { name: "More" }).click()
  await page.getByRole("menuitem", { name: "Unpin", exact: true }).click()
  await expect(alphaRow).toHaveAttribute("data-inline-dialog-pinned", "false")

  await page.getByRole("button", { name: "More" }).click()
  await page.getByRole("menuitem", { name: "Mark Unread" }).click()
  await expect(alphaRow).toHaveAttribute("data-inline-dialog-unread", "true")

  await page.getByRole("button", { name: "More" }).click()
  await page.getByRole("menuitem", { name: "Mark Read" }).click()
  await expect(alphaRow).toHaveAttribute("data-inline-dialog-unread", "false")

  const betaRow = page.locator(
    `[data-inline-sidebar-chat-id="${seed.betaChatId}"]`,
  )
  await betaRow.hover()
  await betaRow.getByRole("button", { name: "Close Beta thread from sidebar" }).click()
  await expect(betaRow).toHaveCount(0)

  expect(remoteRequests).toEqual([])
  expect(browserErrors).toEqual([])
})

test("keeps the primary Mac-shaped actions keyboard operable", async ({
  context,
  page,
}) => {
  test.setTimeout(30_000)
  await installFirstFrameTrace(context)

  const remoteRequests: string[] = []
  const browserErrors: string[] = []
  page.on("request", (request) => {
    const url = new URL(request.url())
    if (url.hostname === "api.inline.chat") {
      remoteRequests.push(`${request.method()} ${url.pathname}`)
    }
  })
  page.on("pageerror", (error) => browserErrors.push(error.message))
  page.on("console", (message) => {
    if (message.type() === "error") browserErrors.push(message.text())
  })

  await page.goto("/login")
  const seed = await page.evaluate<ProductRouteSeed>(`(async () => {
    const harness = await import("/src/testing/product/InlineProductRouteBrowserHarnessPage.ts")
    return await harness.seedInlineProductRouteCache()
  })()`)
  await page.goto("/chats")

  const allChatsView = page.locator("[data-inline-all-chats-layout]")
  const archive = allChatsView.getByRole("button", { name: "Show Archived Chats" })
  await focusByTab(page, archive)
  await page.keyboard.press("Enter")
  await expect(page).toHaveURL(/\/chats\?archived=true$/)

  const showChats = allChatsView.getByRole("button", { name: "Show Chats" })
  await focusByTab(page, showChats)
  await page.keyboard.press("Enter")
  await expect(page).toHaveURL(/\/chats$/)

  const viewOptions = allChatsView.getByRole("button", {
    name: "View Options",
  })
  await focusByTab(page, viewOptions)
  await page.keyboard.press("Enter")
  await page.keyboard.press("ArrowDown")
  await page.keyboard.press("Enter")
  await expect(allChatsView).toHaveAttribute(
    "data-inline-all-chats-layout",
    "titlePreviewLine",
  )

  const alphaRow = page.locator(
    `[data-inline-sidebar-chat-id="${seed.alphaChatId}"]`,
  )
  const alphaLink = alphaRow.getByRole("link", { name: /Alpha thread/ })
  await focusByTab(page, alphaLink)
  await page.keyboard.press("Enter")
  await expect(page).toHaveURL(seed.alphaPath)
  await expect(page.getByText("First cached message").first()).toBeVisible()

  const more = page
    .locator("[data-inline-app-detail]")
    .getByRole("button", { name: "More" })
  await focusByTab(page, more)
  await page.keyboard.press("Enter")
  await expect(page.getByRole("menuitem", { name: "Mark Unread" })).toBeVisible()
  await page.keyboard.press("End")
  await page.keyboard.press("Enter")
  await expect(alphaRow).toHaveAttribute("data-inline-dialog-unread", "true")

  await focusByTab(page, more, { backward: true })
  await page.keyboard.press("Enter")
  await expect(page.getByRole("menuitem", { name: "Mark Read" })).toBeVisible()
  await page.keyboard.press("End")
  await page.keyboard.press("Enter")
  await expect(alphaRow).toHaveAttribute("data-inline-dialog-unread", "false")

  await focusByTab(page, alphaLink, { backward: true })
  await page.keyboard.press("Shift+F10")
  await expect(page.getByRole("menuitem", { name: "Mark Unread" })).toBeVisible()
  await page.keyboard.press("End")
  await page.keyboard.press("Enter")
  await expect(alphaRow).toHaveAttribute("data-inline-dialog-unread", "true")

  await focusByTab(page, alphaLink, { backward: true })
  await page.keyboard.press("Shift+F10")
  await expect(page.getByRole("menuitem", { name: "Mark Read" })).toBeVisible()
  await page.keyboard.press("End")
  await page.keyboard.press("Enter")
  await expect(alphaRow).toHaveAttribute("data-inline-dialog-unread", "false")

  const messages = page.getByLabel("Messages")
  await focusByTab(page, messages)
  await page.keyboard.press("ArrowUp")
  await expect(page.locator('[aria-label="Message actions"]:focus')).toHaveCount(1)
  await page.keyboard.press("Shift+F10")
  const reply = page.getByRole("menuitem", { name: "Reply" })
  await expect(reply).toBeVisible()
  await expect(reply).toBeFocused()
  await page.keyboard.press("Enter")
  const cancelReply = page.getByRole("button", { name: "Cancel reply" })
  await expect(cancelReply).toBeVisible()
  await focusByTab(page, cancelReply)
  await page.keyboard.press("Enter")
  await expect(cancelReply).toHaveCount(0)

  expect(remoteRequests).toEqual([])
  expect(browserErrors).toEqual([])
})

test("persists the Mac appearance modes without losing the cached chat bottom", async ({
  context,
  page,
}) => {
  test.setTimeout(30_000)
  await installFirstFrameTrace(context)

  const remoteRequests: string[] = []
  const browserErrors: string[] = []
  page.on("request", (request) => {
    const url = new URL(request.url())
    if (url.hostname === "api.inline.chat") {
      remoteRequests.push(`${request.method()} ${url.pathname}`)
    }
  })
  page.on("pageerror", (error) => browserErrors.push(error.message))
  page.on("console", (message) => {
    if (message.type() === "error") browserErrors.push(message.text())
  })

  await page.goto("/login")
  const seed = await page.evaluate<ProductRouteSeed>(`(async () => {
    const harness = await import("/src/testing/product/InlineProductRouteBrowserHarnessPage.ts")
    return await harness.seedInlineProductRouteCache()
  })()`)
  await page.goto("/settings")
  await page.getByRole("button", { name: "Appearance" }).click()
  await page.getByRole("radio", { name: "Dark" }).click()
  await page.getByRole("radio", { name: "Compact" }).click()
  await page.getByRole("radio", { name: "Minimal" }).click()

  const root = page.locator("html")
  await expect(root).toHaveAttribute("data-inline-appearance", "dark")
  await expect(root).toHaveAttribute("data-inline-sidebar-item-size", "compact")
  await expect(root).toHaveAttribute("data-inline-message-style", "minimal")
  const sidebar = page.locator("[data-inline-sidebar]")
  await expect(sidebar).toHaveAttribute(
    "data-inline-sidebar-item-size",
    "compact",
  )
  const alphaRow = page.locator(
    `[data-inline-sidebar-chat-id="${seed.alphaChatId}"]`,
  )
  expect((await alphaRow.getByRole("link").boundingBox())?.height).toBe(30)

  await alphaRow.getByRole("link").click()
  const chat = page.locator("[data-inline-chat-at-bottom]")
  const messages = page.locator('[data-inline-message-list="viewport"]')
  await expect(messages).toHaveAttribute("data-inline-message-style", "minimal")
  await expect(chat).toHaveAttribute("data-inline-chat-at-bottom", "true")
  await expect(page.getByText("First cached message").last()).toBeVisible()

  await page.reload()
  await expect(root).toHaveAttribute("data-inline-appearance", "dark")
  await expect(sidebar).toHaveAttribute(
    "data-inline-sidebar-item-size",
    "compact",
  )
  await expect(messages).toHaveAttribute("data-inline-message-style", "minimal")
  await expect(chat).toHaveAttribute("data-inline-chat-at-bottom", "true")
  await expect(page.getByText("First cached message").last()).toBeVisible()

  expect(remoteRequests).toEqual([])
  expect(browserErrors).toEqual([])
})

declare global {
  interface Window {
    inlineProductFrameTrace: {
      frames: () => ProductFrame[]
      reset: () => void
    }
  }
}
