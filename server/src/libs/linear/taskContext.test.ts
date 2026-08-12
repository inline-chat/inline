import { describe, expect, test } from "bun:test"
import { resolveLinearTaskSourceText } from "./taskContext"

const storedMessage = (text: string) => ({
  text,
  textEncrypted: null,
  textIv: null,
  textTag: null,
})

describe("Linear task source text", () => {
  test("uses the authorized stored target instead of caller-provided text", () => {
    const result = resolveLinearTaskSourceText({
      messageId: 42,
      authorizedMessage: storedMessage("Trusted database message"),
      contextMessages: [],
    })

    expect(result).toBe("Trusted database message")
  })

  test("uses the matching stored context row when available", () => {
    const result = resolveLinearTaskSourceText({
      messageId: 42,
      authorizedMessage: storedMessage("Fallback database message"),
      contextMessages: [
        { messageId: 41, text: "Earlier message" },
        { messageId: 42, text: "Bound context target" },
      ],
    })

    expect(result).toBe("Bound context target")
  })
})
