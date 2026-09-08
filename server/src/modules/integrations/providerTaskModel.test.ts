import { describe, expect, test } from "bun:test"
import {
  estimateProviderTaskCostUsd,
  providerTaskModel,
  providerTaskPricingUsdPerMillionTokens,
  providerTaskReasoningEffort,
} from "./providerTaskModel"

describe("provider task model", () => {
  test("uses the shared current quality/cost tier", () => {
    expect(providerTaskModel).toBe("gpt-5.6-terra")
    expect(providerTaskReasoningEffort).toBe("low")
  })

  test("keeps usage telemetry aligned with the configured model pricing", () => {
    expect(providerTaskPricingUsdPerMillionTokens).toEqual({ input: 2.5, output: 15 })
    expect(estimateProviderTaskCostUsd({
      inputTokens: 1_000_000,
      outputTokens: 1_000_000,
    })).toBe(17.5)
  })
})
