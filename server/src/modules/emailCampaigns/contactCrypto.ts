import {
  createHash,
  createHmac,
  randomBytes,
} from "node:crypto"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { normalizeEmail } from "@in/server/utils/normalize"

const getKey = (): Buffer => {
  const value = process.env["ENCRYPTION_KEY"]
  if (!value || !/^[a-fA-F0-9]{64}$/.test(value)) {
    throw new Error("A valid ENCRYPTION_KEY is required for email campaigns")
  }
  return Buffer.from(value, "hex")
}

export const normalizedCampaignEmail = (email: string): string =>
  normalizeEmail(email.trim())

export const emailContactKey = (email: string): string =>
  createHmac("sha256", getKey())
    .update(`inline-email-contact:v1:${normalizedCampaignEmail(email)}`)
    .digest("hex")

export const encryptCampaignString = (value: string): Buffer =>
  Encryption2.encrypt(Buffer.from(value, "utf8"))

export const decryptCampaignString = (value: Buffer): string =>
  Encryption2.decryptToString(value)

export const createUnsubscribeToken = (): string =>
  randomBytes(32).toString("base64url")

export const hashUnsubscribeToken = (token: string): string =>
  createHash("sha256").update(token).digest("hex")
