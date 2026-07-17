/**
 * Paths that currently inherit `server/src/setup.ts`.
 *
 * Keep this boundary explicit until the production cutover deliberately
 * revisits middleware policy. Prefix alone is insufficient because OAuth and
 * the documentation endpoints are mounted outside the legacy setup plugin.
 */
export const usesLegacySetupMiddleware = (
  path: string,
): boolean => {
  if (
    path === "/" ||
    path === "/health" ||
    path === "/health/" ||
    path === "/healthz" ||
    path === "/healthz/"
  ) {
    return true
  }

  if (
    path === "/v1/reference" ||
    path.startsWith("/v1/reference/")
  ) {
    return false
  }

  return (
    path === "/v1" ||
    path.startsWith("/v1/") ||
    path === "/waitlist" ||
    path.startsWith("/waitlist/") ||
    path === "/api/there" ||
    path.startsWith("/api/there/") ||
    path === "/admin" ||
    path.startsWith("/admin/")
  )
}
