import type { Links } from "../platform"
import type { WebEnv } from "./env"

/** The link-scheme allowlist from `chat-ui`, injected so every external URL passes it. */
export type ExternalUrlCheck = (url: string) => boolean

export const createWebLinks = (env: WebEnv, isSafeExternalUrl: ExternalUrlCheck): Links => {
  let initialDeepLink: string | null
  try {
    initialDeepLink = env.window.location.href || null
  } catch {
    initialDeepLink = null
  }
  return {
    openExternal(url) {
      if (!isSafeExternalUrl(url)) return false
      try {
        // With `noopener` the call returns null even on success, so there is nothing to check.
        env.window.open(url, "_blank", "noopener,noreferrer")
        return true
      } catch {
        return false
      }
    },
    initialDeepLink,
    onDeepLink: () => () => {},
  }
}
