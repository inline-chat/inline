import { it, expect } from "bun:test"
import { generateToken, hashToken, secureRandomSixDigitNumber } from "./auth"

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
