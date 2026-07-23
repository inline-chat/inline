/// <reference types="vite/client" />

export {}

declare global {
  type InlineDesktopAuthSession = {
    token: string
    userId: import("@inline/ids").UserID
  }

  type InlineDesktopApi = {
    platform: "darwin" | "linux" | "win32"
    auth: {
      loadSession: () => Promise<{
        session: InlineDesktopAuthSession | null
        storage: "encrypted" | "unavailable"
      }>
      saveSession: (session: InlineDesktopAuthSession) => Promise<boolean>
      clearSession: () => Promise<void>
    }
  }

  interface Window {
    inlineDesktop?: InlineDesktopApi
  }
}
