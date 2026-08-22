import { createServerFn } from "@tanstack/react-start"
import { getCookie } from "@tanstack/react-start/server"
import { isLocale, localeCookieKey, type Locale } from "./preferences"

const oneYearInSeconds = 60 * 60 * 24 * 365

export const getRememberedLocale = createServerFn({ method: "GET" }).handler(() => {
  const locale = getCookie(localeCookieKey)
  return isLocale(locale) ? locale : null
})

export function rememberLocale(locale: Locale) {
  const secure = window.location.protocol === "https:"
  document.cookie = [
    `${localeCookieKey}=${encodeURIComponent(locale)}`,
    "Path=/",
    `Max-Age=${oneYearInSeconds}`,
    "SameSite=Lax",
    secure ? "Secure" : "",
  ]
    .filter(Boolean)
    .join("; ")
}
