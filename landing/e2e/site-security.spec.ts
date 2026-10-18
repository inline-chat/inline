import { expect, test, type Page } from "@playwright/test"

const origin = "http://127.0.0.1:4173"

test.beforeEach(async ({ context }) => {
  // No fixture may reach a production API, websocket, analytics or CDN.
  await context.routeWebSocket("**/*", (socket) => socket.close())
  await context.route("**/*", async (route) => {
    if (new URL(route.request().url()).origin === origin) return route.continue()
    return route.abort()
  })
  await context.addInitScript(() => {
    const violations: string[] = []
    Object.defineProperty(window, "__cspViolations", { value: violations })
    document.addEventListener("securitypolicyviolation", (event) => {
      violations.push(`${event.effectiveDirective} ${event.sample}`)
    })
  })
})

const violations = (page: Page) =>
  page.evaluate(() => (window as unknown as { __cspViolations: string[] }).__cspViolations)

const clickInternalLink = async (page: Page, href: string) => {
  await page.locator(`a[href="${href}"]`).first().click()
  await expect(page).toHaveURL(`${origin}${href}`)
}

test("documents carry a nonce-only script policy with Trusted Types", async ({ request }) => {
  const response = await request.get("/")
  const policy = response.headers()["content-security-policy"] ?? ""
  const nonce = policy.match(/'nonce-([^']+)'/)?.[1]

  expect(nonce).toBeTruthy()
  expect(policy).toMatch(/script-src 'self' 'nonce-[^']+'(;|$)/)
  expect(policy).toContain("require-trusted-types-for 'script'")

  const html = await response.text()
  const inlineScripts = [...html.matchAll(/<script\b[^>]*>/g)]
    .map((match) => match[0])
    .filter((tag) => !tag.includes("src="))
  expect(inlineScripts.length).toBeGreaterThan(0)
  for (const tag of inlineScripts) {
    expect(tag.includes(`nonce="${nonce}"`) || tag.includes(`nonce='${nonce}'`)).toBe(true)
  }
})

test("pages load and navigate client-side without policy violations", async ({ page }) => {
  await page.goto("/docs/realtime-api")
  await page.waitForLoadState("networkidle")
  await expect(page.locator("code.hljs span[class^=hljs-]").first()).toBeVisible()

  await clickInternalLink(page, "/")
  await expect(page.locator('script[type="application/ld+json"]')).toHaveCount(1)
  await clickInternalLink(page, "/download")
  await page.goBack()
  await expect(page).toHaveURL(`${origin}/`)
  await clickInternalLink(page, "/docs")

  expect(await page.evaluate(() => performance.getEntriesByType("navigation").length)).toBe(1)
  expect(await violations(page)).toEqual([])
})

test("retired /app links go home and clear the old client's storage", async ({ page }) => {
  await page.goto("/")
  await page.evaluate(async () => {
    localStorage.setItem("auth-store:token", "42:retired-token")
    localStorage.setItem("auth-store:user-id", "42")
    await new Promise<void>((resolve, reject) => {
      const request = indexedDB.open("inline-auth-session", 1)
      request.onsuccess = () => {
        request.result.close()
        resolve()
      }
      request.onerror = () => reject(request.error)
    })
  })

  await page.goto("/app/login/email")
  await expect(page).toHaveURL(`${origin}/`)

  await expect.poll(() => page.evaluate(() => localStorage.getItem("auth-store:token"))).toBeNull()
  await expect
    .poll(() => page.evaluate(async () => (await indexedDB.databases()).map((database) => database.name)))
    .not.toContain("inline-auth-session")
})
