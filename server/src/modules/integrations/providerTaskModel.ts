/**
 * Shared extraction model for provider task creation. Keep the two task flows
 * on one quality/cost baseline so model upgrades cannot drift by provider.
 */
export const providerTaskModel = "gpt-5.6-terra"
export const providerTaskReasoningEffort = "low" as const

export const providerTaskPricingUsdPerMillionTokens = {
  input: 2.5,
  output: 15,
} as const

export function estimateProviderTaskCostUsd(input: {
  readonly inputTokens: number
  readonly outputTokens: number
}): number {
  return (
    input.inputTokens * providerTaskPricingUsdPerMillionTokens.input
    + input.outputTokens * providerTaskPricingUsdPerMillionTokens.output
  ) / 1_000_000
}
