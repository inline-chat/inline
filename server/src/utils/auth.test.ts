import { it, expect } from "bun:test"
import { generateToken } from "./auth"

it("generates a token", async () => {
  for (let i = 0; i < 10; i++) {
    const { token, tokenHash } = await generateToken(123)
    expect(token).toBeDefined()
    expect(tokenHash).toBeDefined()
  }
})
