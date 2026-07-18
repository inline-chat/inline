export type CoreShutdownSignal =
  | "manual"
  | "SIGINT"
  | "SIGTERM"

const describeFailure = (
  cause: unknown,
): string => {
  if (!(cause instanceof Error)) {
    return String(cause)
  }
  const nested =
    "cause" in cause &&
      cause.cause instanceof Error
      ? `: ${cause.cause.message}`
      : ""
  return `${cause.message}${nested}`
}

export const installCoreShutdownHandlers = (
  shutdown: (
    signal: CoreShutdownSignal,
  ) => Promise<void>,
  {
    exitProcess = false,
  }: {
    readonly exitProcess?: boolean
  } = {},
): (() => void) => {
  const handle = (
    signal: "SIGINT" | "SIGTERM",
  ): void => {
    void shutdown(signal).then(
      () => {
        if (exitProcess) {
          process.exit(
            process.exitCode ?? 0,
          )
        }
      },
      (cause) => {
        console.error(
          "Core server shutdown failed.",
          describeFailure(cause),
        )
        process.exitCode = 1
        if (exitProcess) {
          process.exit(1)
        }
      },
    )
  }
  const onSigint = (): void => {
    handle("SIGINT")
  }
  const onSigterm = (): void => {
    handle("SIGTERM")
  }

  process.once("SIGINT", onSigint)
  process.once("SIGTERM", onSigterm)

  return () => {
    process.off("SIGINT", onSigint)
    process.off("SIGTERM", onSigterm)
  }
}
