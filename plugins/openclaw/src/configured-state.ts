const INLINE_CONFIGURED_ENV_KEYS = ["INLINE_TOKEN", "INLINE_BOT_TOKEN"] as const

export function hasInlineConfiguredState(params: { env?: NodeJS.ProcessEnv }): boolean {
  return INLINE_CONFIGURED_ENV_KEYS.some((key) => {
    const value = params.env?.[key]
    return typeof value === "string" && value.trim().length > 0
  })
}
