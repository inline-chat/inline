import { describe, expect, test } from "bun:test"
import {
  estimateProviderTaskCostUsd,
  providerTaskModel,
  providerTaskPricingUsdPerMillionTokens,
  providerTaskReasoningEffort,
} from "./providerTaskModel"

describe("provider task model", () => {
  test("uses the shared current quality/cost tier", () => {
    expect(providerTaskModel).toBe("gpt-6-astra")
    expect(providerTaskReasoningEffort).toBe("low")
  })

  test("keeps usage telemetry aligned with the configured model pricing", () => {
    expect(providerTaskPricingUsdPerMillionTokens).toEqual({ input: 10, output: 50 })
    expect(estimateProviderTaskCostUsd({
      inputTokens: 10_000,
      outputTokens: 1_000,
    })).toBeCloseTo(0.15)
  })

  test("applies long-context pricing only above 272K input tokens", () => {
    expect(estimateProviderTaskCostUsd({
      inputTokens: 272_000,
      outputTokens: 1_000,
    })).toBeCloseTo(2.77)
    expect(estimateProviderTaskCostUsd({
      inputTokens: 272_001,
      outputTokens: 1_000,
    })).toBeCloseTo(5.51502)
  })
})
