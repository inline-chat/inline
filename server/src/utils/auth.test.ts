import { it, expect } from "bun:test"
import {
  generateLoginChallengeId,
  generateToken,
  hashLoginCode,
  LOGIN_CHALLENGE_ID_LENGTH,
  hashToken,
  normalizeToken,
  secureRandomSixDigitNumber,
  verifyLoginCode,
} from "./auth"

it("generates a token", async () => {
  for (let i = 0; i < 10; i++) {
    const { token, tokenHash } = await generateToken(123)
    expect(token).toBeDefined()
    expect(tokenHash).toBeDefined()
  }
})

it("hashes token", async () => {
  const token = "123:IN1234567890"
  const tokenHash = hashToken(token)
  expect(tokenHash).toBeDefined()
})

it("generates a secure random 6 digit number", async () => {
  const number = secureRandomSixDigitNumber()
  expect(number).toBeDefined()
  expect(number).toBeGreaterThan(100000)
  expect(number).toBeLessThan(1000000)
})

it("normalizes auth tokens", () => {
  expect(normalizeToken(undefined)).toBeNull()
  expect(normalizeToken(123)).toBeNull()
  expect(normalizeToken("")).toBeNull()
  expect(normalizeToken("   ")).toBeNull()

  expect(normalizeToken("123:INabc")).toBe("123:INabc")
  expect(normalizeToken("  123:INabc  ")).toBe("123:INabc")

  expect(normalizeToken("Bearer 123:INabc")).toBe("123:INabc")
  expect(normalizeToken("bearer 123:INabc")).toBe("123:INabc")
  expect(normalizeToken("BEARER 123:INabc")).toBe("123:INabc")
  expect(normalizeToken("Bearer    123:INabc")).toBe("123:INabc")
  expect(normalizeToken("Bearer")).toBeNull()

  // Avoid false positives when the token happens to start with the word "Bearer".
  expect(normalizeToken("BearerINabc")).toBe("BearerINabc")
})

it("hashes and verifies login codes", async () => {
  const code = "123456"
  const codeHash = await hashLoginCode(code)

  expect(codeHash).toBeDefined()
  expect(await verifyLoginCode(code, codeHash)).toBe(true)
  expect(await verifyLoginCode("000000", codeHash)).toBe(false)
})

it("generates a random login challenge id", () => {
  const challengeId = generateLoginChallengeId()
  expect(challengeId.startsWith("lc_")).toBe(true)
  expect(challengeId.length).toBe(LOGIN_CHALLENGE_ID_LENGTH + 3)
})

it("rejects invalid login code shape for hashing", async () => {
  await expect(hashLoginCode("12345")).rejects.toThrow("Login code must be exactly 6 digits")
  await expect(hashLoginCode("abcdef")).rejects.toThrow("Login code must be exactly 6 digits")
})
