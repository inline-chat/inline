export const canonicalConnectorCallbackScheme = "in"

const supportedConnectorCallbackSchemes = new Set([
  canonicalConnectorCallbackScheme,
  "inline",
  "inline-debug",
  "inline-debug-2",
  "inline-dev",
])

export function resolveConnectorCallbackScheme(value: string): string | null {
  const normalized = value.trim().toLowerCase()
  if (normalized === "") return canonicalConnectorCallbackScheme
  return supportedConnectorCallbackSchemes.has(normalized) ? normalized : null
}

export function connectorCallbackUrl(
  provider: "linear" | "notion",
  suffix: string,
  scheme = canonicalConnectorCallbackScheme,
): string {
  return `${scheme}://integrations/${provider}?${suffix}`
}
