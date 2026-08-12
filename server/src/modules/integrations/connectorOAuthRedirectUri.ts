export type ConnectorOAuthRedirectProvider = "linear" | "notion"

const productionBaseUrl = "https://api.inline.chat"

const localBaseUrls: Record<ConnectorOAuthRedirectProvider, string> = {
  // Preserve the callback origins already registered by each development
  // OAuth application when no shared LAN/tunnel origin is configured.
  linear: "http://127.0.0.1:8000",
  notion: "http://localhost:8000",
}

export function connectorOAuthRedirectUri(
  provider: ConnectorOAuthRedirectProvider,
  options: {
    nodeEnv?: string | undefined
    developmentBaseUrl?: string | undefined
  } = {},
): string {
  const nodeEnv = options.nodeEnv ?? process.env.NODE_ENV
  const configuredDevelopmentBaseUrl = options.developmentBaseUrl
    ?? process.env.CONNECTOR_OAUTH_CALLBACK_BASE_URL
  const baseUrl = nodeEnv === "production"
    ? productionBaseUrl
    : configuredDevelopmentBaseUrl?.trim() || localBaseUrls[provider]
  const url = new URL(baseUrl)

  if (
    (url.protocol !== "http:" && url.protocol !== "https:")
    || url.username !== ""
    || url.password !== ""
    || url.search !== ""
    || url.hash !== ""
  ) {
    throw new Error("Connector OAuth callback base URL must be an absolute HTTP(S) origin")
  }

  url.pathname = `/integrations/${provider}/callback`
  return url.toString()
}
