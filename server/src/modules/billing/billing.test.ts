import { describe, expect, test } from "bun:test"
import { createHmac } from "node:crypto"
import { findPlan, prepaidEnd } from "./catalog"
import { loadCheckoutConfig } from "./checkoutClient"
import { grantsAccess, STRIPE_RENEWAL_GRACE_MS } from "./entitlements"
import { verifyCheckoutSignature } from "./signature"

const secret = "s".repeat(40)
const sign = (t: number, body: string, key = secret) => `t=${t},v1=${createHmac("sha256", key).update(`${t}.${body}`).digest("hex")}`

describe("verifyCheckoutSignature", () => {
  const body = '{"id":"evt_1"}'
  const now = 1_800_000_000
  test("accepts a fresh signature over the raw body", () => {
    expect(verifyCheckoutSignature(secret, sign(now, body), body, now)).toBe(true)
  })
  test("rejects a changed body, wrong secret, stale or malformed header", () => {
    expect(verifyCheckoutSignature(secret, sign(now, body), body + " ", now)).toBe(false)
    expect(verifyCheckoutSignature(secret, sign(now, body, "x".repeat(40)), body, now)).toBe(false)
    expect(verifyCheckoutSignature(secret, sign(now - 301, body), body, now)).toBe(false)
    expect(verifyCheckoutSignature(secret, sign(now + 301, body), body, now)).toBe(false)
    expect(verifyCheckoutSignature(secret, "v1=abc", body, now)).toBe(false)
    expect(verifyCheckoutSignature(secret, null, body, now)).toBe(false)
  })
})

describe("grantsAccess", () => {
  const now = Date.UTC(2026, 10, 21)
  const base = { endedAt: null, status: "active", paidThrough: null, funding: "comp" }
  test("open-ended comp is Pro until ended", () => {
    expect(grantsAccess(base, now)).toBe(true)
    expect(grantsAccess({ ...base, endedAt: new Date(now) }, now)).toBe(false)
  })
  test("prepaid and wallet periods end exactly at paid_through", () => {
    expect(grantsAccess({ ...base, funding: "prepaid", paidThrough: new Date(now + 1) }, now)).toBe(true)
    expect(grantsAccess({ ...base, funding: "prepaid", paidThrough: new Date(now - 1) }, now)).toBe(false)
  })
  test("stripe keeps access through renewal grace and past_due, not after cancel", () => {
    const lapsed = new Date(now - STRIPE_RENEWAL_GRACE_MS + 60_000)
    expect(grantsAccess({ ...base, funding: "stripe", paidThrough: lapsed }, now)).toBe(true)
    expect(grantsAccess({ ...base, funding: "stripe", paidThrough: new Date(now - STRIPE_RENEWAL_GRACE_MS - 1) }, now)).toBe(false)
    expect(grantsAccess({ ...base, funding: "stripe", status: "past_due", paidThrough: new Date(now + 1) }, now)).toBe(true)
    expect(grantsAccess({ ...base, funding: "stripe", status: "canceled", paidThrough: new Date(now + 1) }, now)).toBe(false)
  })
})

describe("catalog and config", () => {
  test("list prices match the agreed plans", () => {
    expect(findPlan("pro-monthly")).toMatchObject({ subject: "user", usdCents: 1_000 })
    expect(findPlan("pro-yearly")).toMatchObject({ subject: "user", usdCents: 10_000 })
    expect(findPlan("team-monthly")).toMatchObject({ subject: "space", usdCents: 2_000, perSeat: true })
    expect(findPlan("team-yearly")).toMatchObject({ subject: "space", usdCents: 20_000, perSeat: true })
    expect(findPlan("believer")).toMatchObject({ subject: "user", plan: "believer", interval: "three_years", mode: "subscription", usdCents: 20_000 })
    expect(findPlan("sandbox-test")).toMatchObject({ mode: "payment", testOnly: true })
  })
  test("the sandbox one-time plan lasts thirty days", () => {
    const from = new Date(Date.UTC(2026, 10, 21, 12))
    expect(prepaidEnd(findPlan("sandbox-test")!, from).toISOString()).toBe("2026-12-21T12:00:00.000Z")
  })
  test("config is off without credentials and falls back to the single stored plan", () => {
    expect(loadCheckoutConfig({})).toBeNull()
    const config = loadCheckoutConfig({
      INLINE_CHECKOUT_BASE_URL: "https://checkout.noor.to/", INLINE_CHECKOUT_APP_ID: "inline", INLINE_CHECKOUT_MODE: "test",
      INLINE_CHECKOUT_API_TOKEN: "t", INLINE_CHECKOUT_WEBHOOK_SECRET: "s", INLINE_CHECKOUT_PLAN: "sandbox-test",
    })
    expect(config).toMatchObject({ baseUrl: "https://checkout.noor.to", live: false, plans: ["sandbox-test"] })
  })
})
