import { afterEach, describe, expect, test } from "bun:test"

describe("createIndexedText", () => {
  const originalDebug = process.env["DEBUG"]

  afterEach(() => {
    process.env["DEBUG"] = originalDebug
  })

  test("indexes basic ASCII by UTF-16 position", async () => {
    process.env["DEBUG"] = "1"
    const { createIndexedText } = await import("./entityConversion")
    expect(createIndexedText("Hi")).toBe("0H1i")
  })

  test("indexes surrogate pairs using UTF-16 length", async () => {
    const { createIndexedText } = await import("./entityConversion")
    expect(createIndexedText("😀a")).toBe("0😀2a")
  })

  test("indexes emoji with variation selector using UTF-16 length", async () => {
    const { createIndexedText } = await import("./entityConversion")
    expect(createIndexedText("🛍️A")).toBe("0🛍2️3A")
  })
})
