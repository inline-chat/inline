import {
  makeCandidateHttpApplication,
} from "./http/candidateApplication"
import {
  parseTrustedClientIpHeader,
} from "./http/middleware"
import {
  startCoreProductionServer,
} from "./http/productionHost"
import {
  parseHttpRateLimitMax,
} from "./http/rateLimit"

export {
  makeCoreHttpServerLayer,
  startCoreHttpServer,
  type CoreHttpServerHandle,
  type StartCoreHttpServerOptions,
} from "./http/host"
export {
  startCoreProductionServer,
  type CoreProductionServerHandle,
  type StartCoreProductionServerOptions,
} from "./http/productionHost"
/**
 * Full pre-cutover entry point for the replacement server.
 *
 * It intentionally has the shape of the eventual production root: one Effect
 * application, one Bun listener, raw protobuf realtime, and process-scoped
 * services. `server/src/index.ts` remains production-owned until cutover.
 */
if (import.meta.main) {
  const nodeEnvironment =
    process.env.NODE_ENV ?? "development"
  const clientIpHeader =
    parseTrustedClientIpHeader(
      process.env[
        "INLINE_TRUSTED_CLIENT_IP_HEADER"
      ],
    )
  const application =
    makeCandidateHttpApplication({
      apiBaseUrl:
        process.env["API_BASE_URL"],
      middleware: {
        clientIpHeader,
        isProduction:
          nodeEnvironment === "production",
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
    await startCoreProductionServer({
      application,
      clientIpHeader,
      installSignalHandlers: true,
      port: Number(
        process.env["PORT"] ?? "0",
      ),
    })

  console.info(
    `CORE_CANDIDATE_READY ${handle.port}`,
  )
}
