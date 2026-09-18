import "dotenv/config"
import * as Sentry from "@sentry/bun"
import { beforeSendEvent, beforeSendSpan } from "@in/server/utils/sentryPrivacy"
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
  shouldEnableServerSentry,
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
  coreProductionStartupErrorDetails,
  startCoreProductionServer,
  type CoreProductionServerHandle,
} from "@in/server/core/http/productionHost"
import {
  parseHttpRateLimitMax,
} from "@in/server/core/http/rateLimit"
import {
  EventEmitter,
} from "node:events"
import { assertProviderAuthStartupConfiguration } from "@in/server/modules/auth/provider/startup"
import type { InlineProtocolConfiguration } from "@in/server/modules/inlineProtocol/config"

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
  enabled: shouldEnableServerSentry(NODE_ENV),
  enableLogs: true,
  beforeSendLog,
  beforeSend: beforeSendEvent,
  beforeSendTransaction: beforeSendEvent,
  beforeSendSpan,
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
  readonly inlineProtocolConfiguration?:
    | InlineProtocolConfiguration
    | undefined
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
const startServerWithProcessOwnership = (
  options: StartServerOptions = {},
  startBackgroundProcesses: boolean,
): Promise<CoreProductionServerHandle> => {
  assertProviderAuthStartupConfiguration({
    isProduction: NODE_ENV === "production",
  })
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
    inlineProtocolConfiguration:
      options.inlineProtocolConfiguration,
    installSignalHandlers:
      options.installSignalHandlers ??
      true,
    port: options.port ?? PORT,
    startBackgroundProcesses,
  })
}

export const startServer = (
  options: StartServerOptions = {},
): Promise<CoreProductionServerHandle> =>
  startServerWithProcessOwnership(
    options,
    false,
  )

export const runServer =
  async (
    options: StartServerOptions = {},
  ): Promise<CoreProductionServerHandle> => {
    const handle =
      await startServerWithProcessOwnership(
        options,
        true,
      )
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
  try {
    await runServer()
  } catch (error) {
    const details =
      NODE_ENV === "development" ||
        process.env[
          "INLINE_SERVER_SMOKE"
        ] === "1"
        ? coreProductionStartupErrorDetails(error) ?? error
        : { errorType: "CoreProductionStartupError" }
    Log.shared.fatal(
      "The server failed to start.",
      details,
    )
    process.exitCode = 1
  }
}
