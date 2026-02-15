import { setupTestLifecycle } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { thereUsers, waitlist as waitlistTable } from "@in/server/db/schema"
import { eq } from "drizzle-orm"
import { describe, expect, it } from "bun:test"
import { app } from "../index"

setupTestLifecycle()

describe("extra and integration routes", () => {
  it("creates waitlist subscriptions", async () => {
    const email = "waitlist@test.com"
    const response = await app.handle(
      new Request("http://localhost/waitlist/subscribe", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          email,
          name: "Waitlist User",
          timeZone: "UTC",
          userAgent: "bun-test",
        }),
      }),
    )

    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({ ok: true })

    const rows = await db.select().from(waitlistTable).where(eq(waitlistTable.email, email))
    expect(rows.length).toBe(1)
  })

  it("keeps root healthy even if waitlist subscribe hits duplicate-email failure", async () => {
    const email = "waitlist-dup@test.com"
    const request = new Request("http://localhost/waitlist/subscribe", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email }),
    })

    const first = await app.handle(request.clone())
    expect(first.status).toBe(200)

    const second = await app.handle(request)
    expect(second.status).toBeGreaterThanOrEqual(400)

    const root = await app.handle(new Request("http://localhost/"))
    expect(root.status).toBe(200)
  })

  it("creates there signups", async () => {
    const email = "there@test.com"
    const response = await app.handle(
      new Request("http://localhost/api/there/signup", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          email,
          name: "There User",
          timeZone: "UTC",
        }),
      }),
    )

    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({ ok: true })

    const rows = await db.select().from(thereUsers).where(eq(thereUsers.email, email))
    expect(rows.length).toBe(1)
  })

  it("keeps root healthy even if there signup hits duplicate-email failure", async () => {
    const email = "there-dup@test.com"
    const request = new Request("http://localhost/api/there/signup", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email }),
    })

    const first = await app.handle(request.clone())
    expect(first.status).toBe(200)

    const second = await app.handle(request)
    expect(second.status).toBeGreaterThanOrEqual(400)

    const root = await app.handle(new Request("http://localhost/"))
    expect(root.status).toBe(200)
  })

  it("redirects linear callback to missing_cookie when oauth cookies are absent", async () => {
    const response = await app.handle(
      new Request("http://localhost/integrations/linear/callback?code=test-code&state=test-state"),
    )

    expect(response.status).toBe(302)
    expect(response.headers.get("location")).toBe("in://integrations/linear?success=false&error=missing_cookie")
  })

  it("redirects linear callback to state_mismatch when state cookie does not match", async () => {
    const response = await app.handle(
      new Request("http://localhost/integrations/linear/callback?code=test-code&state=query-state", {
        headers: {
          cookie: "token=1%3AINfake;state=cookie-state;spaceId=1",
        },
      }),
    )

    expect(response.status).toBe(302)
    expect(response.headers.get("location")).toBe("in://integrations/linear?success=false&error=state_mismatch")
  })

  it("redirects notion callback to missing_cookie when oauth cookies are absent", async () => {
    const response = await app.handle(
      new Request("http://localhost/integrations/notion/callback?code=test-code&state=test-state"),
    )

    expect(response.status).toBe(302)
    expect(response.headers.get("location")).toBe("in://integrations/notion?success=false&error=missing_cookie")
  })

  it("redirects notion callback to state_mismatch when state cookie does not match", async () => {
    const response = await app.handle(
      new Request("http://localhost/integrations/notion/callback?code=test-code&state=query-state", {
        headers: {
          cookie: "token=1%3AINfake;state=cookie-state;spaceId=1",
        },
      }),
    )

    expect(response.status).toBe(302)
    expect(response.headers.get("location")).toBe("in://integrations/notion?success=false&error=state_mismatch")
  })
})
