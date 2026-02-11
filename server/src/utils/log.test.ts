import { describe, expect, it } from "bun:test"
import { redactString, redactValue } from "./log"

describe("log redaction", () => {
  it("redacts bearer and bot path tokens in strings", () => {
    const rawToken = "123:INabcdefghijklmnopqrstuvwxyz"
    const encodedToken = "123%3AINabcdefghijklmnopqrstuvwxyz"
    const input = `Authorization: Bearer ${rawToken} path=/bot${rawToken}/sendMessage encoded=/bot${encodedToken}/getMe`

    const output = redactString(input)

    expect(output).toContain("Bearer <redacted>")
    expect(output).toContain("bot<redacted>")
    expect(output).not.toContain(rawToken)
    expect(output).not.toContain(encodedToken)
  })

  it("redacts error message, stack, and nested cause", () => {
    const token = "123:INabcdefghijklmnopqrstuvwxyz"
    const encoded = "123%3AINabcdefghijklmnopqrstuvwxyz"

    const cause = new Error(`cause /bot${token}/deleteMessage`)
    ;(cause as any).stack = `Error: cause /bot${token}/deleteMessage\n    at cause (x.ts:1:1)`

    const error = new Error(`top /bot${encoded}/sendMessage Authorization: Bearer ${token}`)
    ;(error as any).stack = `Error: top /bot${token}/sendMessage Authorization: Bearer ${token}\n    at top (y.ts:1:1)`
    ;(error as any).cause = cause

    const redacted = redactValue(error) as Error
    const redactedCause = (redacted as any).cause as Error

    expect(redacted.message).toContain("bot<redacted>")
    expect(redacted.message).toContain("Bearer <redacted>")
    expect(redacted.message).not.toContain(token)
    expect(redacted.message).not.toContain(encoded)

    expect(typeof redacted.stack).toBe("string")
    expect(redacted.stack!).toContain("bot<redacted>")
    expect(redacted.stack!).toContain("Bearer <redacted>")
    expect(redacted.stack!).not.toContain(token)

    expect(redactedCause.message).toContain("bot<redacted>")
    expect(redactedCause.message).not.toContain(token)
    expect(redactedCause.stack!).toContain("bot<redacted>")
    expect(redactedCause.stack!).not.toContain(token)
  })

  it("redacts sensitive keys in metadata objects", () => {
    const token = "123:INabcdefghijklmnopqrstuvwxyz"
    const input = {
      authorization: `Bearer ${token}`,
      token,
      nested: {
        request: `/bot${token}/getMe`,
      },
    }

    const redacted = redactValue(input) as {
      authorization: string
      token: string
      nested: { request: string }
    }

    expect(redacted.authorization).toBe("<redacted>")
    expect(redacted.token).toBe("<redacted>")
    expect(redacted.nested.request).toContain("bot<redacted>")
    expect(redacted.nested.request).not.toContain(token)
  })
})
