import { setupTestLifecycle } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { thereUsers, waitlist as waitlistTable } from "@in/server/db/schema"
import { Log } from "@in/server/utils/log"
import { eq } from "drizzle-orm"
import { describe, expect, it, spyOn } from "bun:test"
import { useLiveHttpApp } from "./liveHttpApp"

const app = useLiveHttpApp()

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

  it("treats repeated waitlist subscriptions as idempotent", async () => {
    const email = "waitlist-dup@test.com"
    const request = new Request("http://localhost/waitlist/subscribe", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email }),
    })

    const first = await app.handle(request.clone())
    expect(first.status).toBe(200)

    const second = await app.handle(request)
    expect(second.status).toBe(200)
    expect(await second.json()).toEqual({ ok: true })

    const rows = await db.select().from(waitlistTable).where(eq(waitlistTable.email, email))
    expect(rows.length).toBe(1)
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

  it("rejects a linear callback without oauth cookies", async () => {
    const response = await app.handle(
      new Request("http://localhost/integrations/linear/callback?code=test-code&state=test-state"),
    )

    // Effect contract: an unclaimed callback without the browser cookies is not
    // redirected into the app; it reports the expired session and clears cookies.
    expect(response.status).toBe(400)
    expect(response.headers.get("location")).toBeNull()
    expect(await response.json()).toEqual({ error: "OAuth session expired or was already used" })
    expect(response.headers.get("set-cookie")).toContain("state=; Max-Age=0")
  })

  it("rejects a linear callback whose state cookie does not match", async () => {
    const warn = spyOn(Log.shared, "warn")
    const trace = spyOn(Log.shared, "trace")
    try {
      const response = await app.handle(
        new Request("http://localhost/integrations/linear/callback?code=test-code&state=query-state", {
          headers: {
            cookie: "token=1%3AINfake;state=cookie-state;spaceId=1",
          },
        }),
      )

      // Effect contract: a state that does not match the browser session is a
      // 400 for that browser, not an app redirect.
      expect(response.status).toBe(400)
      expect(response.headers.get("location")).toBeNull()
      expect(await response.json()).toEqual({ error: "OAuth state did not match this browser session" })
      expect(response.headers.get("set-cookie")).toContain("state=; Max-Age=0")
      expect(warn).not.toHaveBeenCalled()
      expect(trace).not.toHaveBeenCalled()
    } finally {
      warn.mockRestore()
      trace.mockRestore()
    }
  })

  it("rejects a notion callback without oauth cookies", async () => {
    const response = await app.handle(
      new Request("http://localhost/integrations/notion/callback?code=test-code&state=test-state"),
    )

    // Effect contract: an unclaimed callback without the browser cookies is not
    // redirected into the app; it reports the expired session and clears cookies.
    expect(response.status).toBe(400)
    expect(response.headers.get("location")).toBeNull()
    expect(await response.json()).toEqual({ error: "OAuth session expired or was already used" })
    expect(response.headers.get("set-cookie")).toContain("state=; Max-Age=0")
  })

  it("rejects a notion callback whose state cookie does not match", async () => {
    const warn = spyOn(Log.shared, "warn")
    const trace = spyOn(Log.shared, "trace")
    try {
      const response = await app.handle(
        new Request("http://localhost/integrations/notion/callback?code=test-code&state=query-state", {
          headers: {
            cookie: "token=1%3AINfake;state=cookie-state;spaceId=1",
          },
        }),
      )

      // Effect contract: a state that does not match the browser session is a
      // 400 for that browser, not an app redirect.
      expect(response.status).toBe(400)
      expect(response.headers.get("location")).toBeNull()
      expect(await response.json()).toEqual({ error: "OAuth state did not match this browser session" })
      expect(response.headers.get("set-cookie")).toContain("state=; Max-Age=0")
      expect(warn).not.toHaveBeenCalled()
      expect(trace).not.toHaveBeenCalled()
    } finally {
      warn.mockRestore()
      trace.mockRestore()
    }
  })
})
