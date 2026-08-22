const MCP_ENDPOINT_PATHS = new Set(["/mcp", "/mcp/v2"])

function normalizedPathname(url: URL): string {
  if (url.pathname === "/") return "/"
  return url.pathname.replace(/\/+$/, "")
}

/**
 * Maps the canonical MCP audience and the exact hosted MCP transport URLs to
 * one audience. OAuth clients commonly default the resource indicator to the
 * configured Streamable HTTP endpoint instead of the protected-resource
 * metadata's origin-level identifier.
 */
export function normalizeMcpResourceIndicator(
  requestedResource: string | null | undefined,
  canonicalResource: string,
): string | null {
  if (requestedResource == null) return canonicalResource
  if (requestedResource === canonicalResource) return canonicalResource

  let requested: URL
  let canonical: URL
  try {
    requested = new URL(requestedResource)
    canonical = new URL(canonicalResource)
  } catch {
    return null
  }

  if (
    requested.username
    || requested.password
    || requested.search
    || requested.hash
    || requested.origin !== canonical.origin
  ) {
    return null
  }

  const canonicalPath = normalizedPathname(canonical)
  const requestedPath = normalizedPathname(requested)
  if (requestedPath === canonicalPath) return canonicalResource

  if (canonicalPath === "/" && MCP_ENDPOINT_PATHS.has(requestedPath)) {
    return canonicalResource
  }

  return null
}
