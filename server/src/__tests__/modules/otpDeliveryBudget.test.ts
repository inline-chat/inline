import { describe, expect, it } from "bun:test"
import { db } from "@in/server/db"
import { authDeliveryBudgets } from "@in/server/db/schema/authDeliveryBudgets"
import { reserveOtpDelivery } from "@in/server/modules/auth/otpDeliveryBudget"
import { setupTestLifecycle } from "../database"

describe("shared OTP delivery budgets", () => {
  setupTestLifecycle()
  const contact = { channel: "email" as const, contact: "synthetic@example.test", ip: "192.0.2.1" }

  it("permits only one concurrent reservation for a contact and stores no raw identity", async () => {
    const results = await Promise.all(Array.from({ length: 20 }, () => reserveOtpDelivery(contact)))
    expect(results.filter(Boolean)).toHaveLength(1)
    const rows = await db.select().from(authDeliveryBudgets)
    expect(rows).toHaveLength(4)
    expect(rows.every((row) => row.attempts === 1)).toBe(true)
    expect(JSON.stringify(rows)).not.toContain(contact.contact)
    expect(JSON.stringify(rows)).not.toContain(contact.ip)
  })

  it("enforces cooldown/window and allows a later window", async () => {
    const start = Date.now()
    expect(await reserveOtpDelivery(contact, new Date(start))).toBe(true)
    expect(await reserveOtpDelivery(contact, new Date(start + 59_999))).toBe(false)
    for (let i = 1; i < 5; i++) expect(await reserveOtpDelivery(contact, new Date(start + i * 60_000))).toBe(true)
    expect(await reserveOtpDelivery(contact, new Date(start + 5 * 60_000))).toBe(false)
    expect(await reserveOtpDelivery(contact, new Date(start + 10 * 60_000))).toBe(true)
  })

  it("enforces the provider cap across contacts and rolls back other dimensions on rejection", async () => {
    const previous = process.env["AUTH_OTP_EMAIL_HOURLY_LIMIT"]
    process.env["AUTH_OTP_EMAIL_HOURLY_LIMIT"] = "2"
    try {
      const results = await Promise.all(Array.from({ length: 8 }, (_, i) => reserveOtpDelivery({ ...contact, contact: `${i}@example.test` })))
      expect(results.filter(Boolean)).toHaveLength(2)
      expect(await db.select().from(authDeliveryBudgets)).toHaveLength(6)
    } finally {
      if (previous === undefined) Reflect.deleteProperty(process.env, "AUTH_OTP_EMAIL_HOURLY_LIMIT")
      else process.env["AUTH_OTP_EMAIL_HOURLY_LIMIT"] = previous
    }
  })
})
