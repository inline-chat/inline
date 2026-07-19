import "dotenv/config"
import * as Sentry from "@sentry/bun"
import {
  API_BASE_URL,
  NODE_ENV,
  PORT,
  SENTRY_DSN,
} from "@in/server/env"
import {
  gitCommitHash,
  gitCommitSha,
  version,
} from "@in/server/buildEnv"
import {
  buildServerSentryDist,
  buildServerSentryRelease,
} from "@in/server/utils/sentryRelease"
import {
  beforeSendLog,
  Log,
} from "@in/server/utils/log"
import {
  makeCandidateHttpApplication,
} from "@in/server/core/http/candidateApplication"
import {
  clientIpHeaderForMode,
  parseClientIpMode,
} from "@in/server/core/http/middleware"
import {
  startCoreProductionServer,
  type CoreProductionServerHandle,
} from "@in/server/core/http/productionHost"
import {
  parseHttpRateLimitMax,
} from "@in/server/core/http/rateLimit"
import {
  EventEmitter,
} from "node:events"

const sentryRelease =
  buildServerSentryRelease(
    version,
    gitCommitSha,
  )
const sentryDist =
  buildServerSentryDist(gitCommitSha)

Sentry.init({
  dsn: SENTRY_DSN,
  release: sentryRelease,
  dist: sentryDist,
  environment: NODE_ENV,
  tracesSampleRate: 1,
  enabled: NODE_ENV !== "development",
  enableLogs: true,
  beforeSendLog,
})

// Some database drivers legitimately share more than Node's default listener
// count while the process runtime owns their lifecycle.
EventEmitter.defaultMaxListeners = 20

if (NODE_ENV === "production") {
  process.on("warning", (warning) => {
    if (
      warning?.name ===
        "MaxListenersExceededWarning" &&
      warning.message.includes(
        "wakeup listeners added to [Connection2]",
      )
    ) {
      return
    }
    console.warn(warning)
  })
}

if (NODE_ENV !== "development") {
  Log.shared.info(
    `🚧 Starting server • ${NODE_ENV} • ${version} • ${gitCommitHash}`,
  )
}

export interface StartServerOptions {
  readonly installSignalHandlers?:
    | boolean
    | undefined
  readonly port?: number | undefined
}

/**
 * Production root for HTTP, protobuf realtime, workers, and infrastructure.
 *
 * The deployed request graph is Effect/Bun owned. Retained business functions
 * remain behind the narrow Live adapters until their later module migrations.
 */
export const startServer = (
  options: StartServerOptions = {},
): Promise<CoreProductionServerHandle> => {
  const clientIpMode =
    parseClientIpMode(
      process.env[
        "INLINE_TRUSTED_CLIENT_IP_HEADER"
      ],
      {
        requireExplicit:
          NODE_ENV === "production",
      },
    )
  const clientIpHeader =
    clientIpHeaderForMode(clientIpMode)
  const application =
    makeCandidateHttpApplication({
      apiBaseUrl: API_BASE_URL,
      middleware: {
        clientIpHeader,
        isProduction:
          NODE_ENV === "production",
        rateLimit: {
          max: parseHttpRateLimitMax(
            process.env[
              "INLINE_API_RATE_LIMIT_MAX"
            ],
          ),
        },
      },
    })

  return startCoreProductionServer({
    application,
    clientIpHeader,
    installSignalHandlers:
      options.installSignalHandlers ??
      true,
    port: options.port ?? PORT,
  })
}

export const runServer =
  async (): Promise<CoreProductionServerHandle> => {
    const handle = await startServer()
    Log.shared.info(
      `Running on http://${handle.hostname}:${handle.port}`,
    )
    if (
      NODE_ENV === "test" ||
      process.env[
        "INLINE_SERVER_SMOKE"
      ] === "1"
    ) {
      console.info(
        `SERVER_READY ${handle.port}`,
      )
    }
    return handle
  }

if (import.meta.main) {
  await runServer()
}
