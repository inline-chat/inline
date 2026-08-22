import type { OauthServerConfig } from "./config"

const AUTH_REQUEST_COOKIE_PATH = "/"

export const authRequestCookieName = (
  config: Pick<OauthServerConfig, "cookiePrefix">,
): string => `${config.cookiePrefix}_ar`

export const authRequestCookieHeader = (
  config: Pick<OauthServerConfig, "cookiePrefix" | "issuer">,
  value: string,
  options?: { maxAgeSeconds?: number },
): string => {
  const secure = config.issuer.startsWith("https://")
  const maxAgePart = options?.maxAgeSeconds != null ? `; Max-Age=${options.maxAgeSeconds}` : ""
  return `${authRequestCookieName(config)}=${value}${maxAgePart}; Path=${AUTH_REQUEST_COOKIE_PATH}; HttpOnly; SameSite=Lax${secure ? "; Secure" : ""}`
}
