import { describe, expect, it } from "bun:test"
import {
  createUnsubscribeToken,
  decryptCampaignString,
  emailContactKey,
  encryptCampaignString,
  hashUnsubscribeToken,
} from "./contactCrypto"

describe("email campaign contact crypto", () => {
  it("normalizes contact identity without storing the address in the key", () => {
    const key = emailContactKey("  PERSON@Example.com ")
    expect(key).toBe(emailContactKey("person@example.com"))
    expect(key).toHaveLength(64)
    expect(key).not.toContain("person")
  })

  it("encrypts recipient values and creates opaque unsubscribe tokens", () => {
    const email = "person@example.com"
    const encrypted = encryptCampaignString(email)
    expect(encrypted.toString("utf8")).not.toContain(email)
    expect(decryptCampaignString(encrypted)).toBe(email)

    const token = createUnsubscribeToken()
    expect(token.length).toBeGreaterThanOrEqual(40)
    expect(hashUnsubscribeToken(token)).toHaveLength(64)
  })
})
