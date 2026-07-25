import { shell, type BrowserWindow } from "electron"
import { INLINE_APP_ORIGIN } from "./AppProtocol"

const externalProtocols = new Set(["https:", "mailto:"])

const isAllowedRendererUrl = (rawUrl: string, devOrigin?: string) => {
  try {
    const url = new URL(rawUrl)
    return url.origin === INLINE_APP_ORIGIN || (devOrigin != null && url.origin === devOrigin)
  } catch {
    return false
  }
}

const openExternal = (rawUrl: string) => {
  try {
    const url = new URL(rawUrl)
    if (externalProtocols.has(url.protocol)) {
      void shell.openExternal(url.toString())
    }
  } catch {
    // Reject malformed and non-allowlisted URLs.
  }
}

export const restrictExternalNavigation = (
  window: BrowserWindow,
  devOrigin?: string,
) => {
  window.webContents.on("will-navigate", (event, url) => {
    if (isAllowedRendererUrl(url, devOrigin)) return
    event.preventDefault()
    openExternal(url)
  })

  window.webContents.setWindowOpenHandler(({ url }) => {
    openExternal(url)
    return { action: "deny" }
  })

  window.webContents.on("will-attach-webview", (event) => {
    event.preventDefault()
  })
}
