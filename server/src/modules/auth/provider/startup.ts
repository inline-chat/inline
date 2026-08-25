import { Log } from "@in/server/utils/log"
import {
  providerAuthConfig,
  requireProviderAuthConfig,
  type ProviderAuthConfig,
} from "./config"

/**
 * Production clients expose both provider buttons, so production requires
 * both providers. Local and test servers may run without either provider;
 * configured credentials are still parsed and validated at startup.
 */
export function assertProviderAuthStartupConfiguration(options: {
  isProduction: boolean
  loadConfig?: () => ProviderAuthConfig
}): void {
  try {
    const config = (options.loadConfig ?? providerAuthConfig)()
    if (options.isProduction) requireProviderAuthConfig(config)
  } catch (cause) {
    Log.shared.fatal(
      "Apple and Google sign-in configuration is invalid; refusing to start the server.",
      cause,
    )
    throw cause
  }
}
