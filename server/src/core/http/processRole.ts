export type ServerProcessRole = "api" | "all"

/**
 * Dark validation serves the complete API/Realtime path but must never claim
 * shared worker leases. Production is explicit so a second Machine cannot
 * accidentally become a worker merely because an environment value was lost.
 */
export const parseServerProcessRole = (
  input: string | undefined,
  isProduction: boolean,
): ServerProcessRole => {
  if (input === "api" || input === "all") {
    return input
  }
  if (input === undefined || input.trim() === "") {
    if (!isProduction) {
      return "all"
    }
    throw new Error(
      "INLINE_PROCESS_ROLE must be explicitly set to api or all in production.",
    )
  }
  throw new Error(
    "INLINE_PROCESS_ROLE must be api or all.",
  )
}
