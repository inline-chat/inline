export const DEFAULT_CORE_GRACEFUL_SHUTDOWN_MILLIS =
  20_000

const MIN_CORE_GRACEFUL_SHUTDOWN_MILLIS =
  1_000
const MAX_CORE_GRACEFUL_SHUTDOWN_MILLIS =
  120_000

/**
 * Parses the deadline owned by the current Bun/Effect production host.
 *
 * This is intentionally strict: silently falling back after a deployment
 * configuration typo can make Fly's kill timeout disagree with the
 * application drain deadline.
 */
export const parseCoreGracefulShutdownMillis = (
  input: string | undefined,
): number => {
  if (input === undefined) {
    return DEFAULT_CORE_GRACEFUL_SHUTDOWN_MILLIS
  }
  const value = input.trim()

  if (!/^\d+$/.test(value)) {
    throw new Error(
      "SHUTDOWN_TIMEOUT_MS must be a whole number of milliseconds.",
    )
  }

  const millis = Number(value)
  if (
    !Number.isSafeInteger(millis) ||
    millis < MIN_CORE_GRACEFUL_SHUTDOWN_MILLIS ||
    millis > MAX_CORE_GRACEFUL_SHUTDOWN_MILLIS
  ) {
    throw new Error(
      `SHUTDOWN_TIMEOUT_MS must be between ${MIN_CORE_GRACEFUL_SHUTDOWN_MILLIS} and ${MAX_CORE_GRACEFUL_SHUTDOWN_MILLIS} milliseconds.`,
    )
  }

  return millis
}
