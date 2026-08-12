import type { ConnectorOAuthRedirectProvider } from "./connectorOAuthRedirectUri"

type OAuthEnvironment = Readonly<Record<string, string | undefined>>

export interface ConnectorOAuthCredentials {
  readonly clientId: string
  readonly clientSecret: string
}

export function connectorOAuthCredentials(
  provider: ConnectorOAuthRedirectProvider,
  options: {
    nodeEnv?: string | undefined
    environment?: OAuthEnvironment | undefined
  } = {},
): ConnectorOAuthCredentials | null {
  const environment = options.environment ?? process.env
  const isProduction = (options.nodeEnv ?? environment["NODE_ENV"]) === "production"
  const prefix = provider.toUpperCase()
  const productionId = environment[`${prefix}_CLIENT_ID`]
  const productionSecret = environment[`${prefix}_CLIENT_SECRET`]
  const developmentId = environment[`${prefix}_CLIENT_ID_DEV`]
  const developmentSecret = environment[`${prefix}_CLIENT_SECRET_DEV`]
  if (!isProduction && (developmentId || developmentSecret)) {
    return developmentId && developmentSecret
      ? { clientId: developmentId, clientSecret: developmentSecret }
      : null
  }

  return productionId && productionSecret
    ? { clientId: productionId, clientSecret: productionSecret }
    : null
}
