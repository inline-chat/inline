import {
  startServer,
} from "../index"

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
export {
  startServer,
  type StartServerOptions,
} from "../index"

/**
 * Compatibility entry for the replacement workspace command.
 *
 * Production now uses the same starter directly from `server/src/index.ts`, so
 * this path cannot drift into a second root implementation.
 */
if (import.meta.main) {
  const handle = await startServer()
  console.info(
    `CORE_CANDIDATE_READY ${handle.port}`,
  )
}
