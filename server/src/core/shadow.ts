import {
  startCurrentServer,
  type CurrentServerHandle,
} from "../legacyServer"
import {
  makeCandidateHttpApplication,
} from "./http/candidateApplication"
import {
  startCoreHttpServer,
  type CoreHttpServerHandle,
} from "./http/host"
import {
  clientIpHeaderForMode,
  parseClientIpMode,
} from "./http/middleware"
import {
  parseHttpRateLimitMax,
} from "./http/rateLimit"

export interface StartCoreShadowServerOptions {
  readonly application?:
    | ReturnType<
      typeof makeCandidateHttpApplication
    >
    | undefined
  readonly currentPort?: number | undefined
  readonly installSignalHandlers?:
    | boolean
    | undefined
  readonly replacementHostname?:
    | string
    | undefined
  readonly replacementPort?:
    | number
    | undefined
}

export interface CoreShadowServerHandle {
  readonly current: CurrentServerHandle
  readonly replacement: CoreHttpServerHandle
  readonly shutdown: (
    signal?:
      | "manual"
      | "SIGINT"
      | "SIGTERM",
  ) => Promise<void>
}

const installShadowShutdownHandlers = (
  shutdown: (
    signal: "SIGINT" | "SIGTERM",
  ) => Promise<void>,
): (() => void) => {
  const onSigint = (): void => {
    void shutdown("SIGINT").catch(() => {
      process.exitCode = 1
    })
  }
  const onSigterm = (): void => {
    void shutdown("SIGTERM").catch(() => {
      process.exitCode = 1
    })
  }

  process.once("SIGINT", onSigint)
  process.once("SIGTERM", onSigterm)

  return () => {
    process.off("SIGINT", onSigint)
    process.off("SIGTERM", onSigterm)
  }
}

/**
 * Compatibility oracle harness only.
 *
 * The current Elysia app and Effect HTTP candidate run side by side without
 * giving the candidate a second copy of process singletons. The full candidate
 * entry lives in `core/index.ts`.
 */
export const startCoreShadowServer = async (
  options:
    StartCoreShadowServerOptions = {},
): Promise<CoreShadowServerHandle> => {
  if (process.env.NODE_ENV === "production") {
    throw new Error(
      "The core shadow entry point must not run in production.",
    )
  }

  const application =
    options.application ??
    makeCandidateHttpApplication({
      middleware: {
        isProduction: false,
      },
    })
  const current = startCurrentServer({
    installSignalHandlers: false,
    port: options.currentPort ?? 0,
  })

  let replacement: CoreHttpServerHandle
  try {
    replacement = await startCoreHttpServer({
      application,
      hostname:
        options.replacementHostname,
      installSignalHandlers: false,
      port:
        options.replacementPort ?? 0,
    })
  } catch (error) {
    await current.gracefulShutdown
      .shutdown("error")
    throw error
  }

  let shutdownPromise:
    | Promise<void>
    | undefined
  let removeSignalHandlers = (): void => {}
  const shutdown = (
    signal:
      | "manual"
      | "SIGINT"
      | "SIGTERM" = "manual",
  ): Promise<void> => {
    if (shutdownPromise !== undefined) {
      return shutdownPromise
    }

    removeSignalHandlers()
    shutdownPromise = Promise.all([
      replacement.shutdown(signal),
      current.gracefulShutdown
        .shutdown(signal),
    ]).then(() => {})
    return shutdownPromise
  }

  if (
    options.installSignalHandlers ===
      true
  ) {
    removeSignalHandlers =
      installShadowShutdownHandlers(
        shutdown,
      )
  }

  return {
    current,
    replacement,
    shutdown,
  }
}

if (import.meta.main) {
  const application =
    makeCandidateHttpApplication({
      apiBaseUrl:
        process.env["API_BASE_URL"],
      middleware: {
        clientIpHeader:
          clientIpHeaderForMode(
            parseClientIpMode(
              process.env[
                "INLINE_TRUSTED_CLIENT_IP_HEADER"
              ],
              { requireExplicit: false },
            ),
          ),
        isProduction: false,
        rateLimit: {
          max: parseHttpRateLimitMax(
            process.env[
              "INLINE_API_RATE_LIMIT_MAX"
            ],
          ),
        },
      },
    })
  const handle =
    await startCoreShadowServer({
      application,
      currentPort: Number(
        process.env["PORT"] ?? "0",
      ),
      installSignalHandlers: true,
      replacementPort: Number(
        process.env[
          "INLINE_CORE_HTTP_PORT"
        ] ?? "0",
      ),
    })

  console.info(
    `CORE_SHADOW_READY ${handle.current.server.port} ${handle.replacement.port}`,
  )
}
