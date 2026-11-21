import { createHmac, timingSafeEqual } from "node:crypto"

const header = /^t=(\d{1,12}),v1=([a-f0-9]{64})$/
const toleranceSeconds = 300

/** Verifies `noor-checkout-signature` (t=<unix>,v1=<hex HMAC-SHA256 of "<t>.<raw body>">). */
export const verifyCheckoutSignature = (
  secret: string,
  signature: string | null | undefined,
  rawBody: string,
  nowSeconds = Math.floor(Date.now() / 1000),
): boolean => {
  const parts = header.exec(signature ?? "")
  if (!parts?.[1] || !parts[2]) return false
  const timestamp = Number(parts[1])
  if (Math.abs(nowSeconds - timestamp) > toleranceSeconds) return false
  const expected = createHmac("sha256", secret).update(`${timestamp}.${rawBody}`).digest()
  const supplied = Buffer.from(parts[2], "hex")
  return supplied.length === expected.length && timingSafeEqual(supplied, expected)
}
