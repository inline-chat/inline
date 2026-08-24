import { Log } from "@in/server/utils/log"
import { requireProviderAuthConfig } from "./config"

/**
 * Provider buttons ship in every supported client, so both providers are a
 * server startup invariant rather than an optional request-time capability.
 */
export function assertProviderAuthStartupConfiguration(
  loadConfig: () => unknown = requireProviderAuthConfig,
): void {
  try {
    loadConfig()
  } catch (cause) {
    Log.shared.fatal(
      "Required Apple and Google sign-in configuration is invalid; refusing to start the server.",
      cause,
    )
    throw cause
  }
}
