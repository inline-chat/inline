import { expect, test } from "@playwright/test"

test.beforeEach(async ({ context }) => {
  // No fixture may reach a production API, websocket, analytics or mail provider.
  await context.routeWebSocket("**/*", (socket) => socket.close())
  await context.route("**/*", async (route) => {
    const url = new URL(route.request().url())
    if (url.pathname.startsWith("/v1/")) {
      const headers = { "access-control-allow-origin": "http://127.0.0.1:4173", "access-control-allow-headers": "*" }
      if (route.request().method() === "OPTIONS") return route.fulfill({ status: 204, headers })
      if (url.pathname === "/v1/sendEmailCode") {
        expect(url.searchParams.get("email")).toBe("ci@example.invalid")
        return route.fulfill({ headers, json: { ok: true, result: { challengeToken: "ci-challenge-1" } } })
      }
      if (url.pathname === "/v1/verifyEmailCode") {
        expect(url.searchParams.get("email")).toBe("ci@example.invalid")
        expect(url.searchParams.get("challengeToken")).toBe("ci-challenge-1")
        expect(url.searchParams.get("code")).toBe("123456")
        return route.fulfill({ headers, json: { ok: true, result: { userId: 42, token: "42:ci-browser-token", user: { id: 42, firstName: "CI" } } } })
      }
      return route.abort()
    }
    if (url.origin === "http://127.0.0.1:4173") return route.continue()
    return route.abort()
  })
})

test("logged-out app hydrates and routes to the login flow", async ({ page }) => {
  await page.goto("/app")
  await expect(page).toHaveURL(/\/app\/login\/welcome$/)
  await page.getByRole("link", { name: "Continue", exact: true }).click()
  await expect(page).toHaveURL(/\/app\/login\/email$/)
  await expect(page.getByRole("button", { name: "Continue", exact: true })).toBeDisabled()
})

test("email challenge reaches login and persists across reload while offline", async ({ page }) => {
  await page.goto("/app/login/email")
  await page.getByPlaceholder("Enter your email").fill("ci@example.invalid")
  await page.getByRole("button", { name: "Continue", exact: true }).click()
  await expect(page.getByText("We sent a code to")).toBeVisible()
  await page.getByPlaceholder("Enter the code").fill("123456")
  await page.getByRole("button", { name: "Verify", exact: true }).click()
  await expect(page.getByText("Logged in as user 42")).toBeVisible()
  await page.reload()
  await expect(page.getByText("Logged in as user 42")).toBeVisible()
  await expect(page.getByText("Chats", { exact: true })).toBeVisible()
})

test("missing code details cannot submit or resend", async ({ page }) => {
  await page.goto("/app/login/code")
  await expect(page.getByText("Missing login details. Please return to start again.")).toBeVisible()
  await expect(page.getByPlaceholder("Enter the code")).toBeDisabled()
  await expect(page.getByRole("button", { name: "Verify", exact: true })).toBeDisabled()
  await expect(page.getByRole("button", { name: "Resend code", exact: true })).toBeDisabled()
})

test("legacy browser credentials migrate and remain authenticated after reload", async ({ page }) => {
  await page.goto("/app/login/email")
  await page.evaluate(() => {
    localStorage.setItem("auth-store:token", "42:ci-legacy-token")
    localStorage.setItem("auth-store:user-id", "42")
  })
  await page.goto("/app")
  await expect(page.getByText("Logged in as user 42")).toBeVisible()
  expect(await page.evaluate(() => localStorage.getItem("auth-store:token"))).toBeNull()
  await page.reload()
  await expect(page.getByText("Logged in as user 42")).toBeVisible()
})
