export type InlineDesktopPlatform =
  | "darwin"
  | "linux"
  | "win32"

export type InlineDesktopAuthSession = {
  token: string
  /** Canonical signed-int64 decimal user identity from the Inline protocol. */
  userId: string
}

export type InlineDesktopAuthLoadResult = {
  session: InlineDesktopAuthSession | null
  storage: "encrypted" | "unavailable"
}

export type InlineDesktopApi = {
  platform: InlineDesktopPlatform
  auth: {
    loadSession: () => Promise<InlineDesktopAuthLoadResult>
    saveSession: (session: InlineDesktopAuthSession) => Promise<boolean>
    clearSession: () => Promise<void>
  }
}

export const DesktopIpc = {
  loadSession: "inline:auth:load-session",
  saveSession: "inline:auth:save-session",
  clearSession: "inline:auth:clear-session",
} as const
