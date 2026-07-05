import { describe, expect, it } from "vitest"

describe("package barrel", () => {
  it("can be imported", async () => {
    const mod = await import("./index")
    expect(typeof mod.InlineSdkClient).toBe("function")
  })
})

