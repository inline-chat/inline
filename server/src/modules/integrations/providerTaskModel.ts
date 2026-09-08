/**
 * Shared extraction model for provider task creation. Keep the two task flows
 * on one quality/cost baseline so model upgrades cannot drift by provider.
 */
export const providerTaskModel = "gpt-6-astra"
export const providerTaskReasoningEffort = "low" as const

export const providerTaskPricingUsdPerMillionTokens = {
  input: 10,
  output: 50,
} as const

export function estimateProviderTaskCostUsd(input: {
  readonly inputTokens: number
  readonly outputTokens: number
}): number {
  // Standard processing, uncached estimate. Long-context rates apply to the full request.
  // https://developers.openai.com/api/docs/models/gpt-6-astra
  const isLongContext = input.inputTokens > 272_000
  return (
    input.inputTokens * providerTaskPricingUsdPerMillionTokens.input * (isLongContext ? 2 : 1)
    + input.outputTokens * providerTaskPricingUsdPerMillionTokens.output * (isLongContext ? 1.5 : 1)
  ) / 1_000_000
}
