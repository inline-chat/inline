import {
  startCurrentServer,
  type CurrentServerHandle,
} from "../index"
import {
  makeCandidateHttpApplication,
} from "./http/candidateApplication"
import {
  startCoreHttpServer,
  type CoreHttpServerHandle,
} from "./http/host"
import { parseTrustedClientIpHeader } from "./http/middleware"
import { parseHttpRateLimitMax } from "./http/rateLimit"

export {
  makeCoreHttpServerLayer,
  startCoreHttpServer,
  type CoreHttpServerHandle,
  type StartCoreHttpServerOptions,
} from "./http/host"

export interface StartCoreShadowServerOptions {
  readonly application?:
    | ReturnType<typeof makeCandidateHttpApplication>
    | undefined
  readonly currentPort?: number | undefined
  readonly installSignalHandlers?: boolean | undefined
  readonly replacementHostname?: string | undefined
  readonly replacementPort?: number | undefined
}

export interface CoreShadowServerHandle {
  readonly current: CurrentServerHandle
  readonly replacement: CoreHttpServerHandle
  readonly shutdown: (
    signal?: "manual" | "SIGINT" | "SIGTERM",
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
 * Non-production entry point for continuous replacement work.
 *
 * The current full server remains the process-behavior oracle while the
 * independently composed Effect application runs beside it. Production
 * continues to use `server/src/index.ts` until the final cutover slice.
 */
export const startCoreShadowServer = async (
  options: StartCoreShadowServerOptions = {},
): Promise<CoreShadowServerHandle> => {
  if (process.env.NODE_ENV === "production") {
    throw new Error("The core shadow entry point must not run in production.")
  }

  const application = options.application ?? makeCandidateHttpApplication({
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
      hostname: options.replacementHostname,
      installSignalHandlers: false,
      port: options.replacementPort ?? 0,
    })
  } catch (error) {
    await current.gracefulShutdown.shutdown("error")
    throw error
  }

  let shutdownPromise: Promise<void> | undefined
  let removeSignalHandlers = (): void => {}
  const shutdown = (
    signal: "manual" | "SIGINT" | "SIGTERM" = "manual",
  ): Promise<void> => {
    if (shutdownPromise) {
      return shutdownPromise
    }

    removeSignalHandlers()
    shutdownPromise = Promise.all([
      replacement.shutdown(signal),
      current.gracefulShutdown.shutdown(signal),
    ]).then(() => {})
    return shutdownPromise
  }

  if (options.installSignalHandlers === true) {
    removeSignalHandlers = installShadowShutdownHandlers(shutdown)
  }

  return {
    current,
    replacement,
    shutdown,
  }
}

if (import.meta.main) {
  const application = makeCandidateHttpApplication({
    apiBaseUrl: process.env["API_BASE_URL"],
    middleware: {
      clientIpHeader: parseTrustedClientIpHeader(
        process.env["INLINE_TRUSTED_CLIENT_IP_HEADER"],
      ),
      isProduction: false,
      rateLimit: {
        max: parseHttpRateLimitMax(
          process.env["INLINE_API_RATE_LIMIT_MAX"],
        ),
      },
    },
  })
  const handle = await startCoreShadowServer({
    application,
    currentPort: Number(process.env["PORT"] ?? "0"),
    installSignalHandlers: true,
    replacementPort: Number(
      process.env["INLINE_CORE_HTTP_PORT"] ?? "0",
    ),
  })
  console.info(
    `CORE_SHADOW_READY ${handle.current.server.port} ${handle.replacement.port}`,
  )
}
