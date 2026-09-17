import { createHmac } from "node:crypto"
import { db } from "@in/server/db"
import { authDeliveryBudgets as budgets } from "@in/server/db/schema/authDeliveryBudgets"
import { InlineError } from "@in/server/types/errors"
import { or, lte, lt, sql } from "drizzle-orm"

type Delivery = { channel: "email" | "sms"; contact: string; ip?: string | undefined }
const denied = Symbol("delivery-budget-exhausted")
const MINUTE = 60_000

const providerLimit = (channel: Delivery["channel"]): number => {
  const raw = process.env[channel === "email" ? "AUTH_OTP_EMAIL_HOURLY_LIMIT" : "AUTH_OTP_SMS_HOURLY_LIMIT"]
  if (raw === undefined) return channel === "email" ? 1_000 : 200
  const value = Number(raw)
  if (!Number.isSafeInteger(value) || value < 1 || value > 1_000_000) throw new Error("Invalid OTP provider budget")
  return value
}

/** Shared across entry points and processes. Failed provider attempts still spend the reservation. */
export async function reserveOtpDelivery(input: Delivery, now = new Date()): Promise<boolean> {
  const key = process.env["ENCRYPTION_KEY"]
  if (!key || !/^[a-f0-9]{64}$/i.test(key)) throw new Error("OTP budget key unavailable")
  const hash = (value: string) => createHmac("sha256", Buffer.from(key, "hex")).update(`otp-budget-v1:${value}`).digest("hex")
  const contact = hash(`${input.channel}:${input.contact}`)
  const dimensions = [
    { key: `contact-cooldown:${contact}`, limit: 1, window: MINUTE },
    { key: `contact-window:${contact}`, limit: 5, window: 10 * MINUTE },
    { key: `ip:${hash(input.ip ?? "unknown")}`, limit: 100, window: 10 * MINUTE },
    { key: `provider:${input.channel}`, limit: providerLimit(input.channel), window: 60 * MINUTE },
  ].sort((a, b) => a.key.localeCompare(b.key))
  // Bound retention and avoid waiting for another request's cleanup locks.
  await db.execute(sql`delete from ${budgets} where ${budgets.key} in (
    select "key" from "auth_delivery_budgets" where "expires_at" <= ${now.toISOString()}::timestamptz
    order by "key" limit 100 for update skip locked
  )`)
  try {
    await db.transaction(async (tx) => {
      for (const dimension of dimensions) {
        const expiresAt = new Date(now.getTime() + dimension.window)
        const expired = lte(budgets.expiresAt, now)
        const rows = await tx.insert(budgets).values({ key: dimension.key, attempts: 1, expiresAt })
          .onConflictDoUpdate({
            target: budgets.key,
            set: {
              attempts: sql`case when ${expired} then 1 else ${budgets.attempts} + 1 end`,
              expiresAt: sql`case when ${expired} then ${expiresAt.toISOString()}::timestamptz else ${budgets.expiresAt} end`,
            },
            setWhere: or(expired, lt(budgets.attempts, dimension.limit)),
          }).returning({ key: budgets.key })
        if (rows.length !== 1) throw denied
      }
    })
    return true
  } catch (error) {
    if (error === denied) return false
    throw error
  }
}

export async function assertOtpDeliveryAllowed(input: Delivery): Promise<void> {
  if (!await reserveOtpDelivery(input)) throw new InlineError(InlineError.ApiError.FLOOD)
}
