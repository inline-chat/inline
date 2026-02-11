import { describe, expect, it } from "vitest"
import { InlineAccountSchema, InlineConfigSchema, InlineRuntimeConfigSchema } from "./config-schema"

describe("inline/config-schema", () => {
  it("accepts dmPolicy=open only when allowFrom includes *", () => {
    expect(
      InlineConfigSchema.safeParse({ dmPolicy: "open", allowFrom: ["*"] }).success,
    ).toBe(true)
    expect(InlineConfigSchema.safeParse({ dmPolicy: "open", allowFrom: ["1"] }).success).toBe(
      false,
    )
  })

  it("accounts schema applies the same open allowFrom rule", () => {
    expect(
      InlineAccountSchema.safeParse({ dmPolicy: "open", allowFrom: ["*"] }).success,
    ).toBe(true)
    expect(
      InlineAccountSchema.safeParse({ dmPolicy: "open", allowFrom: ["2"] }).success,
    ).toBe(false)
  })

  it("runtime schema remains lenient so token-only setup does not get dropped", () => {
    expect(
      InlineRuntimeConfigSchema.safeParse({ token: "t", dmPolicy: "open" }).success,
    ).toBe(true)
  })
})
